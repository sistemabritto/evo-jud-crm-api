class Messages::ImageTextExtractionJob < ApplicationJob
  queue_as :low

  def perform(attachment_id)
    attachment = Attachment.find_by(id: attachment_id)
    unless attachment
      Rails.logger.warn "ImageTextExtractionJob: Attachment not found: #{attachment_id}"
      return
    end

    unless attachment.image?
      Rails.logger.info "ImageTextExtractionJob: Attachment #{attachment_id} is not an image (type: #{attachment.file_type})"
      return
    end

    unless attachment.message.incoming?
      Rails.logger.info "ImageTextExtractionJob: Attachment #{attachment_id} message is not incoming"
      return
    end

    Rails.logger.info "ImageTextExtractionJob: Starting text extraction for attachment #{attachment_id}"
    result = Messages::ImageTextExtractionService.new(attachment: attachment).perform

    if result[:error]
      Rails.logger.warn "ImageTextExtractionJob: Extraction failed for attachment #{attachment_id}: #{result[:error]}"
    elsif result[:success]
      Rails.logger.info "ImageTextExtractionJob: Text extracted for attachment #{attachment_id}"
    else
      Rails.logger.warn "ImageTextExtractionJob: Unexpected result for attachment #{attachment_id}: #{result.inspect}"
    end
  rescue StandardError => e
    Rails.logger.error "ImageTextExtractionJob: Error processing attachment #{attachment_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
