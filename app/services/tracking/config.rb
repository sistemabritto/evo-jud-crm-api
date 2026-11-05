# evo-jud-crm: configuração do tracking (Configurações › Admin › Tracking). Tudo opcional:
# sem credenciais o funil do CRM funciona; Meta/Google só entram quando configurados.
module Tracking
  module Config
    KEYS = %w[
      TRACKING_WHATSAPP_NUMBER TRACKING_SCHEDULING_URLS TRACKING_ACQUISITION_INBOX_IDS
      TRACKING_STAGE_MEETING_IDS TRACKING_STAGE_CONTRACT_IDS TRACKING_STAGE_PAYMENT_IDS
      TRACKING_META_AD_ACCOUNT_ID TRACKING_META_ACCESS_TOKEN_SECRET
      TRACKING_META_PIXEL_ID TRACKING_META_CAPI_TOKEN_SECRET TRACKING_META_CAPI_ENABLED
      TRACKING_META_PAGE_ID TRACKING_META_WABA_ID TRACKING_META_WABA_DATASET_ID TRACKING_META_TEST_EVENT_CODE
      TRACKING_GOOGLE_ADS_CUSTOMER_ID TRACKING_GOOGLE_ADS_INGEST_SECRET TRACKING_GOOGLE_CONVERSIONS_FEED_SECRET
      TRACKING_POSTIZ_URL TRACKING_POSTIZ_API_SECRET
      TRACKING_OPENREPLY_URL TRACKING_OPENREPLY_API_SECRET
    ].freeze

    DEFAULT_SCHEDULING = %w[cal.com/ calendly.com/ agenda.].freeze

    module_function

    def get(key, default = nil)
      value = GlobalConfigService.load(key, default)
      value.is_a?(String) ? value.strip : value
    end

    def list(key)
      get(key, '').to_s.split(/[\s,;]+/).map(&:strip).reject(&:empty?)
    end

    def scheduling_patterns
      configured = list('TRACKING_SCHEDULING_URLS')
      (configured.presence || DEFAULT_SCHEDULING).map(&:downcase)
    end

    # Caixas de entrada de aquisição (chip comercial). Vazio = todas. Suporte e outras caixas não
    # entram no funil: nem atribuição, nem conversa iniciada, nem link de agendamento.
    def acquisition_inbox_ids
      list('TRACKING_ACQUISITION_INBOX_IDS')
    end

    def acquisition_inbox?(inbox_id)
      ids = acquisition_inbox_ids
      ids.empty? || ids.include?(inbox_id.to_s)
    end

    def stage_ids(kind)
      list("TRACKING_STAGE_#{kind.to_s.upcase}_IDS")
    end

    def meta_insights?
      get('TRACKING_META_AD_ACCOUNT_ID').present? && get('TRACKING_META_ACCESS_TOKEN_SECRET').present?
    end

    def meta_capi?
      enabled = get('TRACKING_META_CAPI_ENABLED', 'false').to_s == 'true'
      enabled && get('TRACKING_META_PIXEL_ID').present? && capi_token.present?
    end

    def capi_token
      get('TRACKING_META_CAPI_TOKEN_SECRET').presence || get('TRACKING_META_ACCESS_TOKEN_SECRET')
    end

    # Origens que o Meta consegue atribuir: anúncio, pixel do site, Instagram e posts/respostas
    # publicados no Facebook/Instagram pelo Postiz e pelo OpenReply. Contatos sem origem (clientes
    # antigos, equipe) e do Google não vão para a CAPI.
    CAPI_CHANNELS = %w[meta site instagram postiz openreply].freeze

    def capi_contact?(contact)
      CAPI_CHANNELS.include?((contact&.custom_attributes || {})['origem_canal'].to_s)
    end

    # Conjunto de dados ligado à WABA (eventos business_messaging, com ctwa_clid). Usa o token do
    # usuário do sistema, que precisa ter esse conjunto de dados atribuído no portfólio.
    def waba_dataset
      get('TRACKING_META_WABA_DATASET_ID').presence
    end

    def waba_capi_token
      get('TRACKING_META_ACCESS_TOKEN_SECRET').presence || capi_token
    end

    def google_ingest_secret
      get('TRACKING_GOOGLE_ADS_INGEST_SECRET')
    end
  end
end
