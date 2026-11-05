# evo-jud-crm: grava o marco do funil (idempotente: a primeira ocorrência de cada etapa vale).
# Pagamentos somam o valor de cada cobrança nova (external_id) no mesmo marco.
module Tracking
  module Recorder
    module_function

    def record!(contact:, stage:, occurred_at: Time.current, conversation: nil, source: 'crm',
                value_cents: nil, external_id: nil, metadata: {})
      return if contact.nil?

      existing = TrackingEvent.find_by(contact_id: contact.id, stage: stage)
      return add_payment(existing, value_cents, external_id) if existing

      meta = metadata.to_h.stringify_keys
      meta['pagamentos'] = [external_id] if stage == 'pagamento_efetuado' && external_id.present?
      event = TrackingEvent.create!(contact_id: contact.id, conversation_id: conversation&.id, stage: stage,
                                    occurred_at: occurred_at || Time.current, source: source,
                                    value_cents: value_cents, external_id: external_id, metadata: meta)
      Tracking::CapiJob.perform_later(event.id) if Tracking::Config.meta_capi?
      event
    rescue ActiveRecord::RecordNotUnique
      TrackingEvent.find_by(contact_id: contact.id, stage: stage)
    end

    def add_payment(event, value_cents, external_id)
      return event unless event.stage == 'pagamento_efetuado' && value_cents.to_i.positive? && external_id.present?

      pagos = Array(event.metadata['pagamentos'])
      return event if pagos.include?(external_id)

      event.update!(value_cents: event.value_cents.to_i + value_cents.to_i,
                    metadata: event.metadata.merge('pagamentos' => pagos + [external_id]))
      event
    end

    # Contato por id, telefone (8 últimos dígitos, por causa do 9º dígito) ou e-mail.
    def find_contact(contact_id: nil, phone: nil, email: nil)
      return Contact.find_by(id: contact_id) if contact_id.present?

      if phone.present?
        digits = phone.to_s.gsub(/\D/, '')
        if digits.length >= 8
          found = Contact.where("regexp_replace(coalesce(phone_number,''), '\\D', '', 'g') LIKE ?", "%#{digits.last(8)}").limit(2).to_a
          return found.first if found.size == 1
        end
      end
      return Contact.where('lower(email) = ?', email.to_s.downcase.strip).first if email.present?

      nil
    end
  end
end
