# evo-jud-crm: de onde veio o contato.
#
# Mensagens prontas terminam com um código entre colchetes:
#   [INV1]   anúncio do Meta direto para o WhatsApp (sem prefixo = Meta, padrão histórico)
#   [GINV1]  anúncio do Google Ads      [SINV1] botão do site
#   [PINV1]  post publicado pelo Postiz [OINV1] resposta automática do OpenReply
#   [IG1]    Instagram orgânico (bio, stories)
# O anúncio de clique para WhatsApp também manda `ad_referral` (externalAdReply), que vale
# como Meta mesmo sem código. A primeira origem nunca é sobrescrita; a última sempre é.
module Tracking
  module Attribution
    AREAS = {
      'GER' => 'geral', 'INV' => 'inventario', 'DIV' => 'divorcio', 'IMO' => 'imobiliario',
      'EXT' => 'exterior', 'PRE' => 'previdenciario', 'CIV' => 'civel', 'ELE' => 'eleitoral',
      'AGR' => 'agrario', 'AMB' => 'ambiental', 'ADM' => 'administrativo'
    }.freeze
    PREFIX_CHANNEL = { nil => 'meta', 'S' => 'site', 'G' => 'google', 'P' => 'postiz', 'O' => 'openreply' }.freeze
    CHANNEL_PREFIX = PREFIX_CHANNEL.invert.freeze
    CHANNELS = %w[meta google site instagram postiz openreply organico].freeze
    PAID = %w[meta google].freeze
    CODE = /\[(?<prefix>[SGPO])?(?<area>[A-Z]{3})(?<n>\d{1,3})\]\s*\z/
    IG_CODE = /\[IG(?<n>\d{1,3})\]\s*\z/

    module_function

    # => { channel:, campaign:, area:, ad_id:, ctwa_clid: } ou nil
    def parse(text, referral = nil)
      text = text.to_s
      origin = nil
      if (m = text.match(CODE))
        origin = { channel: PREFIX_CHANNEL[m[:prefix]], campaign: "#{m[:prefix]}#{m[:area]}#{m[:n]}".downcase,
                   area: AREAS[m[:area]] }
      elsif (m = text.match(IG_CODE))
        origin = { channel: 'instagram', campaign: "ig#{m[:n]}", area: nil }
      end
      ref = referral.is_a?(Hash) ? referral.with_indifferent_access : nil
      if ref.present? && (ref[:sourceID].present? || ref[:ctwaClid].present? || ref[:sourceType].to_s.casecmp('ad').zero?)
        origin = (origin || { campaign: nil, area: nil }).merge(channel: 'meta')
        origin[:ad_id] = ref[:sourceID].presence
        origin[:ctwa_clid] = ref[:ctwaClid].presence
        origin[:campaign] ||= ref[:sourceID].present? ? "ad-#{ref[:sourceID]}" : nil
      end
      origin
    end

    # Grava a origem no contato (primeira e última) e as etiquetas na conversa.
    def apply!(contact, conversation, origin, at: Time.current)
      return if contact.nil? || origin.blank?

      attrs = (contact.custom_attributes || {}).dup
      if attrs['origem_canal'].blank?
        attrs['origem_canal'] = origin[:channel]
        attrs['origem_campanha'] = origin[:campaign] if origin[:campaign]
        attrs['origem_area'] = origin[:area] if origin[:area]
        attrs['origem_at'] = at.iso8601
      end
      attrs['origem_anuncio_id'] ||= origin[:ad_id] if origin[:ad_id]
      attrs['origem_ctwa_clid'] = origin[:ctwa_clid] if origin[:ctwa_clid]
      attrs['origem_ultimo_canal'] = origin[:channel]
      attrs['origem_ultima_campanha'] = origin[:campaign] if origin[:campaign]
      contact.update!(custom_attributes: attrs) if attrs != contact.custom_attributes

      return unless conversation

      labels = ["origem-#{origin[:channel]}"]
      labels << "campanha-#{origin[:campaign]}" if origin[:campaign] && !origin[:campaign].start_with?('ad-')
      new_labels = (conversation.label_list.to_a + labels).uniq
      conversation.update!(label_list: new_labels) if new_labels.size != conversation.label_list.to_a.size
    end

    # Correção manual (ferramenta MCP / tela): sobrescreve a primeira origem.
    def set!(contact, channel:, campaign: nil)
      raise ArgumentError, "canal inválido: #{channel}" unless CHANNELS.include?(channel)

      attrs = (contact.custom_attributes || {}).dup
      attrs['origem_canal'] = channel
      attrs['origem_campanha'] = campaign.presence&.downcase
      attrs['origem_at'] ||= Time.current.iso8601
      attrs['origem_manual'] = true
      contact.update!(custom_attributes: attrs)
    end

    # Link wa.me com a frase pronta e o código do canal.
    def link(number:, channel:, area:, variant: 1, text: nil)
      prefix = channel == 'instagram' ? nil : CHANNEL_PREFIX.fetch(channel)
      code = channel == 'instagram' ? "IG#{variant}" : "#{prefix}#{area}#{variant}"
      phrase = "#{text.presence || default_phrase(channel, AREAS[area])} [#{code}]"
      { code: code, text: phrase, url: "https://wa.me/#{number.to_s.gsub(/\D/, '')}?text=#{ERB::Util.url_encode(phrase)}" }
    end

    def default_phrase(channel, area_name)
      assunto = area_name && area_name != 'geral' ? " sobre #{area_name}" : ''
      case channel
      when 'meta', 'google' then "Olá! Vi o anúncio#{assunto} e quero orientação."
      when 'site' then "Olá! Vim pelo site e quero orientação#{assunto}."
      when 'instagram' then 'Olá! Vim pelo Instagram e quero falar com o escritório.'
      else "Olá! Vi a publicação#{assunto} e quero orientação."
      end
    end
  end
end
