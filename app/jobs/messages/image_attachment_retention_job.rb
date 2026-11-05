# LGPD minimization: document photos are the most personal thing the client
# sends. Once the words are in meta['transcribed_text'], the pixels do not need
# to live forever. Opt-in through IMAGE_ATTACHMENT_RETENTION_DAYS so an
# installation that never sets it keeps today's behaviour.
class Messages::ImageAttachmentRetentionJob < ApplicationJob
  queue_as :housekeeping

  def perform
    days = ENV.fetch('IMAGE_ATTACHMENT_RETENTION_DAYS', '').to_i
    return if days <= 0

    purged = 0
    Attachment.where(file_type: :image)
              .where("meta->>'image_purged_at' IS NULL")
              .where('attachments.created_at < ?', days.days.ago)
              .includes(:file_attachment)
              .find_each do |attachment|
      next unless attachment.file.attached?

      attachment.file.purge_later
      attachment.update_columns(meta: (attachment.meta || {}).merge('image_purged_at' => Time.current.iso8601))
      purged += 1
    end

    Rails.logger.info "[ImageAttachmentRetentionJob] purged #{purged} image(s) older than #{days} day(s)"
  end
end
