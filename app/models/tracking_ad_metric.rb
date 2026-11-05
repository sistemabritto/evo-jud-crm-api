# evo-jud-crm: métricas diárias por campanha (Meta e Google Ads).
class TrackingAdMetric < ApplicationRecord
  PLATFORMS = %w[meta google].freeze
  validates :platform, inclusion: { in: PLATFORMS }
  validates :date, :campaign_id, presence: true
end
