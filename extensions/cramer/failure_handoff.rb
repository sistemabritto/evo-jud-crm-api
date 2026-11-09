# frozen_string_literal: true
# Loaded by the existing native_replies initializer; no new service or environment setting.
module CramerFailureHandoff
  VERSION = '2026-11-07.3'
  BOT_IDS = %w[9de95c53-65f8-4af4-8348-07b1faf6ab92 2dc0c549-2d9f-415b-8c59-0250339a0f35].freeze
  EMAIL_BOT_ID = 'fd345baa-a80a-4db8-b384-c53ebb071c4f'
  ANDRE_ID = 'cab27585-2c41-4c0d-86ba-26b0552fd48f'
  NOTICE = 'Vou passar o seu atendimento para um dos assistentes do escritório, que vai entrar em contato com você o mais breve possível. 🙏'
  LEGACY = 'Tive uma instabilidade aqui, mas já já te respondo. 🙏'
  DEFAULT = 'We are having a temporary issue and could not answer right now. We will get back to you shortly.'
  BLOCK = 'cramer_failure_human_required'
  CLAIM = 'cramer_failure_notice_claimed_at'
  NOTICE_KEY = 'cramer_failure_notice'
  DENY_LABELS = %w[equipe interno interna ignorar parceiro comercial empresa banco loja automatico automatica verificado opt-out fora-do-escopo].freeze

  def self.failure?(content)
    [LEGACY, DEFAULT, NOTICE].include?(content.to_s.strip)
  end

  def self.blocked?(conversation)
    conversation.custom_attributes.to_h[BLOCK] == true
  end

  def self.target?(bot, conversation)
    BOT_IDS.include?(bot&.id) || (bot&.id == EMAIL_BOT_ID && conversation.inbox.channel_type == 'Channel::Email')
  end

  # Explicit, trusted CRM classification is necessary. contact_type=lead alone is
  # insufficient: imports and automatic contact creation may set it indiscriminately.
  # No contact is reclassified by this patch. Missing metadata fails closed.
  def self.public_allowed?(conversation)
    return false unless conversation.inbox.channel_type == 'Channel::Whatsapp'
    contact = conversation.contact
    attrs = contact.custom_attributes.to_h
    extra = contact.additional_attributes.to_h
    labels = (contact.label_list.to_a + conversation.label_list.to_a).map { |v| normalize(v) }
    return false if (labels & DENY_LABELS).any?
    return false if CramerCare.internal?(conversation)
    return false if User.where('lower(email) = ?', contact.email.to_s.downcase).exists? && contact.email.present?
    name = normalize(contact.name)
    return false if name.match?(/\b(daniel|anna|ana|rafael|marina|andre|vivo|banco|bank|loja|comunica|automatico|automatica|bot)\b/)
    return false if User.pluck(:name, :display_name).flatten.compact.any? { |n| normalize(n).present? && normalize(n) == name }
    return false if attrs['nao_contatar'].to_s == 'true'
    return false if (attrs.to_a + extra.to_a).any? { |k, v| k.to_s.match?(/business|verified|comercial|automatic|internal|equipe/) && ![nil, false, '', 'false', 0, '0'].include?(v) }
    return false unless %w[lead customer].include?(contact.contact_type)
    # Existing cliente-ativo label or an explicit audience confirmation is required.
    # Absence of a business flag
    # or a name heuristic never promotes an unknown contact to a client.
    labels.include?('cliente-ativo') || %w[cliente lead].include?(attrs['cramer_failure_notice_audience'])
  end

  def self.normalize(value)
    I18n.transliterate(value.to_s).downcase.strip
  end

  def self.handle!(conversation, bot, reason: 'runtime_failure_or_timeout_unspecified')
    # Reason is an enum, never raw provider error text or request payload.
    reason = 'runtime_failure_or_timeout_unspecified' unless %w[timeout runtime_failure runtime_failure_or_timeout_unspecified].include?(reason)
    Rails.logger.warn("[CramerFailure] agent=#{bot.id} agent_name=#{bot.id == BOT_IDS.first ? 'secretaria_cramer' : (bot.id == BOT_IDS.last ? 'antonella_atendimento' : 'gestor_emails_cramer')} conversation=#{conversation.id} reason=#{reason}")
    conversation.with_lock do
      attrs = conversation.custom_attributes.to_h
      first = attrs[CLAIM].nil? && !conversation.messages.where(
        message_type: :outgoing, private: false, content: [LEGACY, DEFAULT, NOTICE]).exists?
      allowed = first && public_allowed?(conversation)
      # Persistent decision for the lifetime of the conversation, even when
      # suppressed. Row lock + message and marker in one transaction prevent races.
      attrs[CLAIM] ||= Time.current.iso8601
      attrs[BLOCK] = true
      attrs['cramer_failure_count'] = attrs.fetch('cramer_failure_count', 0).to_i + 1
      attrs['cramer_failure_last_at'] = Time.current.iso8601
      Label.find_or_create_by!(title: 'falha-ia')
      assignment = { status: :open, assignee_id: ANDRE_ID }
      assignment[:team_id] = nil if conversation.team && !conversation.team.members.exists?(id: ANDRE_ID)
      conversation.update!(**assignment,
        label_list: (conversation.label_list.to_a + ['falha-ia']).uniq, custom_attributes: attrs)
      conversation.messages.create!(inbox: conversation.inbox, message_type: :outgoing, private: true,
        content: "Falha da IA; atendimento humano atribuído a André Cramer. Agente: #{bot.id}. Motivo: #{reason}. Aviso público: #{allowed ? 'autorizado' : 'suprimido'}. IA bloqueada até devolução explícita ao bot.")
      if allowed
        conversation.messages.create!(inbox: conversation.inbox, message_type: :outgoing,
          sender: bot, content: NOTICE, content_attributes: { NOTICE_KEY => true })
      end
    end
  end

  module Postback
    def postback
      conversation = Conversation.find_by(display_id: params[:conversation_display_id])
      return super unless conversation
      bot = find_active_agent_bot(conversation)
      return super unless CramerFailureHandoff.target?(bot, conversation)
      if CramerFailureHandoff.failure?(params[:content])
        CramerFailureHandoff.handle!(conversation, bot)
        return render json: { status: 'human_handoff' }, status: :ok
      end
      return render json: { status: 'discarded' }, status: :ok if CramerFailureHandoff.blocked?(conversation)
      super
    end
  end

  module Delegation
    def delegate
      return if CramerFailureHandoff.blocked?(@conversation.reload)
      super
    end
  end

  module Eligibility
    def processing_block_reason(conversation)
      return 'cramer_failure_human_required' if CramerFailureHandoff.blocked?(conversation.reload)
      super
    end
  end

  module ReturnToBot
    def return_to_bot!
      return super unless CramerFailureHandoff.blocked?(self)
      raise Conversations::InvalidHandoffError, 'human operator required' unless Current.user.is_a?(User)
      with_lock do
        result = super
        update!(custom_attributes: custom_attributes.merge(CramerFailureHandoff::BLOCK => false,
          'cramer_failure_returned_by' => Current.user.id, 'cramer_failure_returned_at' => Time.current.iso8601))
        result
      end
    end
  end

  # Also stops replies already queued before the failure. The failure notice is
  # the sole exception and its audience is rechecked immediately before delivery.
  module Delivery
    def perform(message_id)
      message = Message.find(message_id)
      return super unless message.sender_type == 'AgentBot' && (BOT_IDS + [EMAIL_BOT_ID]).include?(message.sender_id)
      if message.content_attributes.to_h[NOTICE_KEY] != true && CramerFailureHandoff.failure?(message.content)
        CramerFailureHandoff.handle!(message.conversation, message.sender)
        return
      end
      if message.content_attributes.to_h[NOTICE_KEY] == true
        claimed = false
        message.conversation.with_lock do
          return unless CramerFailureHandoff.public_allowed?(message.conversation)
          message.with_lock do
            return if message.content_attributes.to_h['cramer_failure_delivery_attempted_at']
            message.update_columns(content_attributes: message.content_attributes.to_h.merge(
              'cramer_failure_delivery_attempted_at' => Time.current.iso8601))
            claimed = true
          end
        end
        # Commit the attempt BEFORE external I/O. On ambiguous delivery failure,
        # never retry this public notice (at-most-once, possible loss is preferable).
        return super if claimed
      else
        message.conversation.with_lock do
          return if CramerFailureHandoff.blocked?(message.conversation)
          super
        end
      end
    end
  end
end

Rails.application.config.to_prepare do
  Webhooks::BotRuntimeController.prepend(CramerFailureHandoff::Postback)
  BotRuntime::DelegationService.prepend(CramerFailureHandoff::Delegation)
  AgentBotInbox.prepend(CramerFailureHandoff::Eligibility)
  Conversation.prepend(CramerFailureHandoff::ReturnToBot)
  SendReplyJob.prepend(CramerFailureHandoff::Delivery)
end
