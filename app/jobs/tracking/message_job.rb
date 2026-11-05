# evo-jud-crm: cada mensagem nova alimenta o funil (origem, conversa iniciada, link de agendamento).
module Tracking
  class MessageJob < ApplicationJob
    queue_as :low

    def perform(message_id)
      message = Message.find_by(id: message_id)
      return if message.nil? || message.private?

      conversation = message.conversation
      contact = conversation&.contact
      return if contact.nil? || conversation.inbox&.channel_type == 'Channel::Email'

      if message.incoming?
        origin = Tracking::Attribution.parse(message.content, message.content_attributes&.dig('ad_referral'))
        Tracking::Attribution.apply!(contact, conversation, origin, at: message.created_at) if origin
        Tracking::Recorder.record!(contact: contact, stage: 'conversa_iniciada', occurred_at: message.created_at,
                                   conversation: conversation, metadata: origin ? { origem: origin[:channel] } : {})
      elsif scheduling_link?(message.content)
        Tracking::Recorder.record!(contact: contact, stage: 'link_agendamento_enviado', occurred_at: message.created_at,
                                   conversation: conversation)
      end
    end

    private

    URL = %r{(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s]*)?}i

    def scheduling_link?(content)
      urls = content.to_s.downcase.scan(URL)
      urls.any? { |url| Tracking::Config.scheduling_patterns.any? { |p| url.include?(p) } }
    end
  end
end
