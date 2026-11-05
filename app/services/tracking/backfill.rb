# evo-jud-crm: monta o funil a partir do histórico (idempotente; pode rodar de novo).
#   bundle exec rails tracking:backfill
module Tracking
  module Backfill
    module_function

    def run!(since: nil)
      stats = Hash.new(0)
      scope = Conversation.joins(:inbox).where.not(inboxes: { channel_type: 'Channel::Email' })
      scope = scope.where('conversations.created_at >= ?', since) if since
      inboxes = Tracking::Config.acquisition_inbox_ids
      scope = scope.where(inbox_id: inboxes) if inboxes.any?
      scope.find_each do |conversation|
        contact = conversation.contact
        next unless contact

        messages = conversation.messages.where(private: false).order(:created_at)
        first_in = messages.where(message_type: :incoming).first
        if first_in
          origin = Tracking::Attribution.parse(first_in.content, first_in.content_attributes&.dig('ad_referral'))
          origin ||= legacy_origin(contact)
          Tracking::Attribution.apply!(contact, conversation, origin, at: first_in.created_at) if origin
          stats[:conversas] += 1 if Tracking::Recorder.record!(contact: contact, stage: 'conversa_iniciada', occurred_at: first_in.created_at,
                                                               conversation: conversation, source: 'backfill')
        end
        link = messages.where(message_type: :outgoing).find { |m| scheduling?(m.content) }
        if link
          stats[:links] += 1 if Tracking::Recorder.record!(contact: contact, stage: 'link_agendamento_enviado', occurred_at: link.created_at,
                                                           conversation: conversation, source: 'backfill')
        end
      end
      PipelineItem.find_each do |item|
        Tracking::PipelineStageJob.perform_now(item.id)
      end
      stats
    end

    # Origem gravada pelo fluxo antigo (cramer_origem_primeira = código do link de campanha).
    def legacy_origin(contact)
      code = contact.custom_attributes&.dig('cramer_origem_primeira')
      return nil if code.blank?

      Tracking::Attribution.parse("[#{code.to_s.upcase}]")
    end

    def scheduling?(content)
      urls = content.to_s.downcase.scan(Tracking::MessageJob::URL)
      urls.any? { |url| Tracking::Config.scheduling_patterns.any? { |p| url.include?(p) } }
    end
  end
end
