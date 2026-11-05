# frozen_string_literal: true

# Reads the text out of an incoming image (photo of a document, ID, receipt)
# and stores it in attachment.meta['transcribed_text'] — the same field audio
# transcription uses, so the rest of the pipeline (delegation to the agent,
# serializer, operator UI) picks it up with no extra wiring.
#
# This is a complement to the bot-runtime's own vision support, not a
# replacement: when the extraction succeeds the words travel even if the
# provider refuses the image part; when it fails the image is still forwarded
# untouched.
class Messages::ImageTextExtractionService
  include Events::Types
  pattr_initialize [:attachment!]

  # Extraction only: reads what is written, no legal interpretation. The agent
  # prompt owns the "do not analyse" rule.
  PROMPT = <<~PROMPT.squish
    Transcreva fielmente todo o texto legível nesta imagem, preservando a ordem
    e os rótulos (por exemplo "Nome:", "CPF:", "RG:", "Endereço:"). Para CPF, RG,
    CNPJ, telefone e número de processo, transcreva somente os dígitos, sem
    pontuação. Se algo estiver ilegível, escreva [ilegível] no lugar. Se a imagem
    não tiver texto, responda exatamente SEM_TEXTO. Não resuma, não interprete e
    não dê opinião.
  PROMPT

  MAX_CHARS = 4000
  MAX_BYTES = 15.megabytes

  def perform
    return { error: 'Attachment is not an image' } unless attachment.image?

    if attachment.meta&.[]('transcribed_text').present?
      return { error: 'Text extraction already exists' }
    end

    # The message callback and the delegation gate can both enqueue extraction;
    # only one should hit the provider.
    unless Redis::Alfred.set("image_text_extraction:#{attachment.id}", 1, nx: true, ex: 180)
      return { error: 'Text extraction already in progress' }
    end

    endpoint = Ai::CredentialResolver.resolve_endpoint(for_consumer: :image_text_extraction)
    if endpoint.key.blank?
      Rails.logger.warn(
        'ImageTextExtractionService: no AI credential resolved ' \
        '(register one under Settings > AI Credentials)'
      )
      return { error: 'No AI credential' }
    end

    return { error: 'Image is too large' } if attachment.file.blob.byte_size > MAX_BYTES

    text = extract_text(endpoint)
    return { error: 'Text extraction failed' } if text.blank?

    save_text(text)
    { success: true, transcribed_text: text }
  rescue StandardError => e
    Rails.logger.error "ImageTextExtractionService: Error for attachment #{attachment.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { error: e.message }
  end

  private

  def extract_text(endpoint)
    response = call_vision_api(endpoint)
    return nil if response.nil?

    content = response.dig('choices', 0, 'message', 'content')
    content = content.filter_map { |part| part['text'] if part.is_a?(Hash) }.join("\n") if content.is_a?(Array)
    text = content.to_s.strip
    return nil if text.blank? || text == 'SEM_TEXTO'

    text.first(MAX_CHARS)
  end

  def call_vision_api(endpoint)
    uri = URI("#{base_url(endpoint)}/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 15
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{endpoint.key}"
    request['Content-Type'] = 'application/json'
    request.body = {
      model: model,
      temperature: 0,
      max_tokens: 1500,
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: PROMPT },
          { type: 'image_url', image_url: { url: image_data_url, detail: 'high' } }
        ]
      }]
    }.to_json

    response = http.request(request)
    unless response.code == '200'
      Rails.logger.error "ImageTextExtractionService: API error #{response.code} for attachment #{attachment.id}: #{response.body[0..300]}"
      return nil
    end

    JSON.parse(response.body)
  end

  def base_url(endpoint)
    url = endpoint.base_url.presence || GlobalConfigService.load('OPENAI_API_URL', 'https://api.openai.com/v1')
    url.chomp('/')
  end

  # Kept separate from OPENAI_TRANSCRIPTION_MODEL (audio) so switching OCR
  # providers does not silently break transcription, and vice versa.
  def model
    GlobalConfigService.load('OPENAI_IMAGE_TEXT_MODEL', 'gpt-4o-mini')
  end

  def image_data_url
    blob = attachment.file.blob
    "data:#{blob.content_type};base64,#{Base64.strict_encode64(attachment.file.download)}"
  end

  def save_text(text)
    attachment.meta ||= {}
    attachment.meta['transcribed_text'] = text
    attachment.meta['text_extraction'] = 'image'
    attachment.meta['text_extracted_at'] = Time.current.iso8601
    attachment.save!

    message = attachment.message
    attachment.reload
    message.reload
    message.association(:attachments).reset

    Rails.configuration.dispatcher.dispatch(
      MESSAGE_UPDATED,
      Time.zone.now,
      message: message,
      previous_changes: { 'attachments' => [attachment.id] }
    )

    Rails.logger.info "ImageTextExtractionService: text saved for attachment #{attachment.id}"
  end
end
