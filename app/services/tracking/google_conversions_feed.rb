# evo-jud-crm: conversões offline para o Google Ads, buscadas pelo próprio Google Ads num horário
# programado (sem API). Só contatos de origem google; etapas reunião, contrato e pagamento dos
# últimos 90 dias. Cada linha leva o gclid (quando o clique veio do site com aceite) e o e-mail e o
# telefone em SHA-256 (conversões otimizadas para leads).
# Para não contar duas vezes linhas sem gclid, cada evento só aparece nas buscas das 36 h seguintes
# à primeira vez que saiu na planilha.
require 'csv'

module Tracking
  module GoogleConversionsFeed
    NAMES = {
      'reuniao_agendada' => 'Reunião agendada',
      'contrato_assinado' => 'Contrato assinado',
      'pagamento_efetuado' => 'Pagamento efetuado'
    }.freeze
    HEADER = ['Google Click ID', 'Email', 'Phone Number', 'Conversion Name', 'Conversion Time',
              'Conversion Value', 'Conversion Currency'].freeze
    WINDOW = 36.hours

    module_function

    def csv(now: Time.current)
      events = TrackingEvent.joins(:contact)
                            .where(stage: NAMES.keys, occurred_at: (now - 90.days)..now)
                            .where("contacts.custom_attributes->>'origem_canal' = 'google'")
                            .includes(:contact).order(:occurred_at)
      rows = []
      events.each do |ev|
        first = ev.metadata['google_feed_at']
        next if first.present? && Time.zone.parse(first) < now - WINDOW

        row = row_for(ev)
        next unless row

        ev.update_columns(metadata: ev.metadata.merge('google_feed_at' => now.iso8601)) if first.blank?
        rows << row
      end
      # Cabeçalho na 1ª linha (conexão HTTPS do Google Ads); fuso vai na própria hora.
      CSV.generate { |c| c << HEADER; rows.each { |r| c << r } }
    end

    def row_for(event)
      contact = event.contact
      attrs = contact.custom_attributes || {}
      gclid = attrs['origem_gclid'].presence
      email = contact.email.to_s.strip.downcase.presence
      phone = e164(contact.phone_number)
      return nil if gclid.nil? && email.nil? && phone.nil?

      value = event.stage == 'pagamento_efetuado' && event.value_cents.to_i.positive? ? format('%.2f', event.value_cents / 100.0) : nil
      [gclid, email && sha(email), phone && sha(phone), NAMES[event.stage],
       event.occurred_at.in_time_zone('America/Bahia').strftime('%Y-%m-%d %H:%M:%S%:z'), value, value && 'BRL']
    end

    def e164(raw)
      digits = raw.to_s.gsub(/\D/, '')
      return nil if digits.length < 10

      "+#{digits.start_with?('55') ? digits : "55#{digits}"}"
    end

    def sha(value)
      Digest::SHA256.hexdigest(value)
    end
  end
end
