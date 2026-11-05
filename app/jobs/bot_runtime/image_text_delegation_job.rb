# Runs the image text extraction that DelegationService waits for, then hands
# the message to the agent. Extraction failure is not fatal: the delegation is
# retried with wait_for_images off, and the image itself still travels as a
# file part for providers that can see it.
class BotRuntime::ImageTextDelegationJob < ApplicationJob
  queue_as :default

  def perform(agent_bot_id, message_id)
    message = Message.includes(attachments: { file_attachment: :blob }).find_by(id: message_id)
    return unless message

    message.attachments.select(&:image?).each do |attachment|
      next if attachment.meta&.[]('transcribed_text').present?

      Messages::ImageTextExtractionService.new(attachment: attachment).perform
    end

    BotRuntime::DelegationService.new(
      AgentBot.find_by(id: agent_bot_id), message, message.conversation,
      has_attachments: message.attachments.any?, wait_for_images: false, dedup: false
    ).delegate
  end
end
