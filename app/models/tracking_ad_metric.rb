# evo-jud-crm: métricas diárias por campanha (Meta e Google Ads) e cliques no WhatsApp do site
# (platform 'site', campaign_id = código da mensagem: SINV1 orgânico, GINV1 Google, INV1 Meta).
class TrackingAdMetric < ApplicationRecord
  ADS_PLATFORMS = %w[meta google].freeze
  PLATFORMS = (ADS_PLATFORMS + %w[site]).freeze
  validates :platform, inclusion: { in: PLATFORMS }
  validates :date, :campaign_id, presence: true
end
