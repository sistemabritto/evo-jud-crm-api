module Tracking
  class MetaInsightsJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      return unless Tracking::Config.meta_insights?

      Tracking::MetaApi.sync_insights!
    rescue StandardError => e
      Rails.logger.warn("[Tracking] Meta insights: #{e.message}")
    end
  end
end
