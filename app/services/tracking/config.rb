# evo-jud-crm: configuração do tracking (Configurações › Admin › Tracking). Tudo opcional:
# sem credenciais o funil do CRM funciona; Meta/Google só entram quando configurados.
module Tracking
  module Config
    KEYS = %w[
      TRACKING_WHATSAPP_NUMBER TRACKING_SCHEDULING_URLS
      TRACKING_STAGE_MEETING_IDS TRACKING_STAGE_CONTRACT_IDS TRACKING_STAGE_PAYMENT_IDS
      TRACKING_META_AD_ACCOUNT_ID TRACKING_META_ACCESS_TOKEN_SECRET
      TRACKING_META_PIXEL_ID TRACKING_META_CAPI_TOKEN_SECRET TRACKING_META_CAPI_ENABLED
      TRACKING_META_PAGE_ID TRACKING_META_WABA_ID TRACKING_META_TEST_EVENT_CODE
      TRACKING_GOOGLE_ADS_CUSTOMER_ID TRACKING_GOOGLE_ADS_INGEST_SECRET
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

    def google_ingest_secret
      get('TRACKING_GOOGLE_ADS_INGEST_SECRET')
    end
  end
end
