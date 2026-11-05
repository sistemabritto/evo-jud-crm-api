module Tracking
  class CapiJob < ApplicationJob
    queue_as :low
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(event_id)
      event = TrackingEvent.find_by(id: event_id)
      return if event.nil? || event.capi_sent_at.present? || !Tracking::Config.meta_capi?
      return unless Tracking::Config.capi_contact?(event.contact)

      Tracking::MetaApi.send_capi!(event)
    end
  end
end
