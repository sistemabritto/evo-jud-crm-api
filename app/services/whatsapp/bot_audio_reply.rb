# frozen_string_literal: true

# Respostas do bot em mensagem de voz, para quem pede áudio ou lê com dificuldade.
#
# Liga com BOT_AUDIO_REPLIES=true e uma chave OpenAI em OPENAI_TTS_API_KEY ou no
# arquivo OPENAI_TTS_API_KEY_FILE (Docker secret). Vale para mensagens públicas do
# AgentBot, sem anexo, em conversas cujo contato prefere áudio:
#   - contact.custom_attributes['prefere_audio'] == true  -> áudio
#   - == false                                            -> sempre texto (opt-out manual)
#   - ausente: procura nas últimas mensagens recebidas (texto ou transcrição do
#     áudio) um pedido de áudio / dificuldade de leitura; achando, grava true.
# Qualquer falha devolve nil e a mensagem segue em texto, como antes.
class Whatsapp::BotAudioReply
  # Pedido para a gente responder em áudio (imperativo, "pode falar...", "áudio pra mim")
  # ou dificuldade de leitura. Não casa com o cliente contando que mandou áudio.
  PEDIDO_AUDIO = /
    \b(?:fal[ae]|mand[ae]|respond[ae]|envi[ae]|grav[ae])\b\s+(?:\S+\s+){0,3}?(?:em|por|um|de)\s+[áa]udio |
    \b(?:pode|poderia|podia|consegue|d[áa]\s+pra|tem\s+como)\s+(?:me\s+)?(?:falar|mandar|responder|enviar|gravar)\s+(?:\S+\s+){0,3}?(?:em|por|um|de)\s+[áa]udio |
    \b(?:falar|mandar|responder|enviar|gravar)\s+(?:em|por)\s+[áa]udio\s+(?:pra|para)\s+mim |
    [áa]udio\s+(?:pra|para)\s+mim |
    \b(?:s[óo]|prefiro|melhor)\s+(?:por|em)\s+[áa]udio |
    \b(?:n[ãa]o\s+sei|sei\s+pouco|n[ãa]o\s+consigo|dificuldade\s+(?:pra|para|de|em))\s+(?:\S+\s+){0,2}?ler\b |
    \bleitura\s+(?:[ée]\s+)?(?:pouca|fraca|ruim|dif[íi]cil)\b |
    \b(?:semi.?)?analfabet
  /xi
  MAX_CHARS = 4000
  TTS_URL = 'https://api.openai.com/v1/audio/speech'

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('BOT_AUDIO_REPLIES', 'false')) && api_key.present?
  end

  def self.api_key
    file = ENV['OPENAI_TTS_API_KEY_FILE'].presence
    return File.read(file).strip if file && File.readable?(file)

    ENV['OPENAI_TTS_API_KEY'].presence
  end

  def initialize(message)
    @message = message
    @conversation = message.conversation
    @contact = @conversation&.contact
  end

  # Anexa o áudio na própria mensagem e devolve true; nil quando não se aplica.
  def attach_audio!
    return unless self.class.enabled? && eligible? && wants_audio?

    audio = synthesize(speech_text)
    return if audio.blank?

    @message.attachments.create!(
      file_type: :audio,
      fallback_title: 'resposta.mp3',
      file: { io: StringIO.new(audio), filename: "resposta-#{@message.id}.mp3", content_type: 'audio/mpeg' }
    )
    @message.update_columns(content_attributes: @message.content_attributes.to_h.merge('bot_audio_reply' => true))
    @message.attachments.reload
    true
  rescue StandardError => e
    Rails.logger.warn "[BotAudioReply] fallback para texto (msg #{@message&.id}): #{e.class}"
    nil
  end

  def eligible?
    @message.outgoing? && !@message.private? && @message.sender_type == 'AgentBot' &&
      @message.attachments.blank? && @message.content.to_s.strip.present? && @contact.present? &&
      # Mensagem de voz não leva legenda: com link, vai em texto para o link chegar.
      !@message.content.to_s.match?(%r{https?://|www\.}i)
  end

  def wants_audio?
    pref = @contact.custom_attributes.to_h['prefere_audio']
    return true if pref == true || pref.to_s == 'true'
    return false if pref == false || pref.to_s == 'false'
    return false unless asked_for_audio?

    @contact.update!(custom_attributes: @contact.custom_attributes.to_h.merge('prefere_audio' => true))
    Rails.logger.info "[BotAudioReply] contato #{@contact.id} pediu áudio; prefere_audio=true"
    true
  end

  def asked_for_audio?
    recent = @conversation.messages.where(message_type: :incoming).order(created_at: :desc).limit(10)
    recent.any? do |m|
      texts = [m.content.to_s] + m.attachments.map { |a| a.meta.to_h['transcribed_text'].to_s }
      texts.any? { |t| t.match?(PEDIDO_AUDIO) }
    end
  end

  # Texto falado: sem markdown/links, que soariam estranhos em voz.
  def speech_text
    t = @message.content.to_s.dup
    t.gsub!(/\[([^\]]+)\]\([^)]+\)/, '\1')
    t.gsub!(%r{https?://\S+}, 'o link que enviei por escrito')
    t.gsub!(/[*_~`#>]/, '')
    t.squeeze(' ').strip[0, MAX_CHARS]
  end

  def synthesize(text)
    resp = HTTParty.post(
      TTS_URL,
      headers: { 'Authorization' => "Bearer #{self.class.api_key}", 'Content-Type' => 'application/json' },
      body: {
        model: ENV.fetch('BOT_AUDIO_TTS_MODEL', 'gpt-4o-mini-tts'),
        voice: ENV.fetch('BOT_AUDIO_TTS_VOICE', 'coral'),
        input: text,
        instructions: 'Fale em português do Brasil, com sotaque brasileiro natural, tom acolhedor e calmo, ' \
                      'como uma secretária de escritório de advocacia explicando algo com paciência.',
        response_format: 'mp3'
      }.to_json,
      timeout: 60
    )
    unless resp.success?
      Rails.logger.warn "[BotAudioReply] TTS HTTP #{resp.code}"
      return nil
    end
    resp.body.to_s.b
  end
end
