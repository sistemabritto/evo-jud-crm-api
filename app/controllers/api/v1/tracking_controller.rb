# evo-jud-crm: funil de tráfego (painel "Tráfego" e ferramentas MCP).
class Api::V1::TrackingController < Api::V1::BaseController
  require_permissions({
    funnel: 'dashboard.read',
    campaigns: 'dashboard.read',
    status: 'dashboard.read',
    links: 'dashboard.read',
    create_event: 'contacts.update',
    set_origin: 'contacts.update'
  })

  def funnel
    success_response(data: query.call, message: 'Funnel retrieved successfully')
  end

  def campaigns
    success_response(data: query.campaigns, message: 'Campaigns retrieved successfully')
  end

  def status
    cfg = Tracking::Config
    success_response(data: {
      meta_insights: cfg.meta_insights?, meta_capi: cfg.meta_capi?,
      meta_last_sync_at: cfg.get('TRACKING_META_LAST_SYNC_AT'),
      google_ads_customer_id: cfg.get('TRACKING_GOOGLE_ADS_CUSTOMER_ID'),
      google_ingest: cfg.google_ingest_secret.present?,
      google_last_ingest_at: cfg.get('TRACKING_GOOGLE_LAST_INGEST_AT'),
      postiz: cfg.get('TRACKING_POSTIZ_URL').present?, openreply: cfg.get('TRACKING_OPENREPLY_URL').present?,
      whatsapp_number: cfg.get('TRACKING_WHATSAPP_NUMBER'),
      stages: { meeting: cfg.stage_ids(:meeting), contract: cfg.stage_ids(:contract), payment: cfg.stage_ids(:payment) },
      events: TrackingEvent.group(:stage).count, ad_metric_days: TrackingAdMetric.group(:platform).count
    }, message: 'Tracking status')
  end

  # Links wa.me com frase pronta e código de origem, por canal e área.
  def links
    number = params[:number].presence || Tracking::Config.get('TRACKING_WHATSAPP_NUMBER')
    return error_response(ApiErrorCodes::INVALID_PARAMETER, 'Configure o número do WhatsApp em Tracking', status: :unprocessable_entity) if number.blank?

    channels = params[:channel].present? ? [params[:channel]] : %w[meta google site postiz openreply]
    areas = params[:area].present? ? [params[:area].to_s.upcase] : Tracking::Attribution::AREAS.keys
    variant = params[:variant].presence&.to_i || 1
    data = channels.flat_map do |ch|
      next [Tracking::Attribution.link(number: number, channel: 'instagram', area: nil, variant: variant).merge(channel: 'instagram')] if ch == 'instagram'

      areas.map { |a| Tracking::Attribution.link(number: number, channel: ch, area: a, variant: variant, text: params[:text]).merge(channel: ch, area: a) }
    end
    success_response(data: data, message: 'Links generated')
  rescue KeyError
    error_response(ApiErrorCodes::INVALID_PARAMETER, 'Canal inválido', status: :unprocessable_entity)
  end

  # Marco vindo de fora (Asaas, DocuSeal, Cal.com, conector): stage + contato por id, telefone ou e-mail.
  def create_event
    stage = params[:stage].to_s
    return error_response(ApiErrorCodes::INVALID_PARAMETER, 'Etapa inválida', status: :unprocessable_entity) unless TrackingEvent::STAGES.include?(stage)

    contact = Tracking::Recorder.find_contact(contact_id: params[:contact_id], phone: params[:phone], email: params[:email])
    return error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Contato não encontrado', status: :not_found) unless contact

    value = params[:value_cents].presence&.to_i || (params[:value].present? ? (params[:value].to_f * 100).round : nil)
    at = params[:occurred_at].present? ? Time.zone.parse(params[:occurred_at].to_s) : Time.current
    event = Tracking::Recorder.record!(contact: contact, stage: stage, occurred_at: at, source: params[:source].presence || 'api',
                                       value_cents: value, external_id: params[:external_id].presence)
    success_response(data: event.as_json(only: %i[id contact_id stage occurred_at value_cents source]), message: 'Event recorded')
  end

  def set_origin
    contact = Contact.find_by(id: params[:contact_id])
    return error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Contato não encontrado', status: :not_found) unless contact

    Tracking::Attribution.set!(contact, channel: params[:channel].to_s, campaign: params[:campaign])
    success_response(data: contact.reload.custom_attributes.slice('origem_canal', 'origem_campanha'), message: 'Origin updated')
  rescue ArgumentError => e
    error_response(ApiErrorCodes::INVALID_PARAMETER, e.message, status: :unprocessable_entity)
  end

  private

  def query
    from = params[:from].present? ? Date.parse(params[:from]) : 30.days.ago.to_date
    to = params[:to].present? ? Date.parse(params[:to]) : Date.current
    Tracking::FunnelQuery.new(channel: params[:channel].presence || 'todos', from: from, to: to)
  end
end
