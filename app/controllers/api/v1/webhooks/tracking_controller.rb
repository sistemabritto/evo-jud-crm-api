# evo-jud-crm: recebe as métricas diárias do Google Ads (script colado na conta do Google Ads).
# Autenticação: cabeçalho X-Tracking-Secret = TRACKING_GOOGLE_ADS_INGEST_SECRET.
class Api::V1::Webhooks::TrackingController < ActionController::API
  def google_ads
    secret = Tracking::Config.google_ingest_secret.to_s
    given = request.headers['X-Tracking-Secret'].to_s
    return head(:unauthorized) if secret.blank? || !ActiveSupport::SecurityUtils.secure_compare(secret, given)

    rows = Array(params[:rows]).first(5000)
    rows.each do |r|
      r = r.respond_to?(:to_unsafe_h) ? r.to_unsafe_h : r.to_h
      next if r['date'].blank? || r['campaign_id'].blank?

      cost = r['cost_micros'].present? ? (r['cost_micros'].to_i / 10_000) : (r['cost'].to_f * 100).round
      Tracking::MetaApi.upsert_metric('google', r['date'], r['campaign_id'], r['campaign_name'],
                                      spend_cents: cost, impressions: r['impressions'].to_i, clicks: r['clicks'].to_i,
                                      conversations: r['conversions'].to_f.round)
    end
    GlobalConfig.set('TRACKING_GOOGLE_LAST_INGEST_AT', Time.current.iso8601)
    render json: { ok: true, rows: rows.size }
  end

  # Clique no botão de WhatsApp do site (navigator.sendBeacon, corpo = código da mensagem).
  # Público e anônimo: só conta cliques por dia e código. Limite por IP no Rack::Attack.
  SITE_CODE = /\A(?:[SGPO]?[A-Z]{3}\d{1,3}|IG\d{1,3})\z/

  def site_click
    code = (request.raw_post.presence || params[:code]).to_s.strip.upcase.first(12)
    return head(:no_content) unless SITE_CODE.match?(code)

    now = Time.current
    TrackingAdMetric.upsert(
      { platform: 'site', date: Date.current, campaign_id: code, campaign_name: 'Site', spend_cents: 0,
        impressions: 0, clicks: 1, conversations: 0, created_at: now, updated_at: now },
      unique_by: %i[platform date campaign_id],
      on_duplicate: Arel.sql('clicks = tracking_ad_metrics.clicks + 1, updated_at = EXCLUDED.updated_at')
    )
    head :no_content
  end
end
