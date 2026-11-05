# evo-jud-crm: funil por coorte. Entram os contatos cuja conversa começou no período e cuja
# origem bate com o filtro; cada etapa seguinte conta a primeira ocorrência daquele contato.
module Tracking
  class FunnelQuery
    FILTERS = (Tracking::Attribution::CHANNELS + %w[pago todos]).freeze
    STAGE_LABELS = {
      'cliques' => 'Cliques para iniciar conversa',
      'conversa_iniciada' => 'Conversa iniciada',
      'link_agendamento_enviado' => 'Link de agendamento enviado',
      'reuniao_agendada' => 'Reunião agendada',
      'contrato_assinado' => 'Contrato assinado',
      'pagamento_efetuado' => 'Pagamento efetuado'
    }.freeze
    EXCLUDED_LABELS = %w[equipe].freeze

    def initialize(channel: 'todos', from: 30.days.ago.to_date, to: Date.current)
      @channel = FILTERS.include?(channel.to_s) ? channel.to_s : 'todos'
      @from = from.to_date
      @to = to.to_date
    end

    def contact_ids
      @contact_ids ||= begin
        range = @from.in_time_zone.beginning_of_day..@to.in_time_zone.end_of_day
        scope = Contact.where(id: TrackingEvent.where(stage: 'conversa_iniciada', occurred_at: range).select(:contact_id))
        scope = filter_channel(scope)
        excluded = Contact.tagged_with(EXCLUDED_LABELS, any: true).select(:id)
        scope.where.not(id: excluded).pluck(:id)
      end
    end

    def call
      ids = contact_ids
      counts = TrackingEvent.where(contact_id: ids).group(:stage).count
      revenue = TrackingEvent.where(contact_id: ids, stage: 'pagamento_efetuado').sum(:value_cents)
      ads = ad_totals
      stages = []
      stages << { key: 'cliques', value: ads[:clicks] } if ads
      TrackingEvent::STAGES.each { |s| stages << { key: s, value: counts[s].to_i } }
      top = stages.first[:value].to_i
      prev = nil
      stages.each do |st|
        st[:label] = STAGE_LABELS[st[:key]]
        st[:pct_top] = pct(st[:value], top)
        st[:pct_prev] = prev.nil? ? nil : pct(st[:value], prev)
        prev = st[:value]
      end
      spend = ads ? ads[:spend_cents] : 0
      {
        channel: @channel, from: @from.iso8601, to: @to.iso8601, stages: stages,
        ads: ads, revenue_cents: revenue,
        costs: ads ? {
          per_click_cents: div(spend, ads[:clicks]),
          per_conversation_cents: div(spend, counts['conversa_iniciada']),
          per_meeting_cents: div(spend, counts['reuniao_agendada']),
          per_contract_cents: div(spend, counts['contrato_assinado']),
          roas: spend.positive? ? (revenue.to_f / spend).round(2) : nil
        } : nil,
        by_channel: by_channel
      }
    end

    def campaigns
      rows = Contact.where(id: contact_ids).pluck(:id, Arel.sql("custom_attributes->>'origem_canal'"), Arel.sql("custom_attributes->>'origem_campanha'"))
      events = TrackingEvent.where(contact_id: rows.map(&:first)).pluck(:contact_id, :stage, :value_cents)
      by_contact = events.group_by(&:first)
      codes = rows.group_by { |r| [r[1] || 'organico', r[2] || '(sem código)'] }.map do |(canal, code), list|
        stage_counts = Hash.new(0)
        revenue = 0
        list.each do |(cid, _, _)|
          Array(by_contact[cid]).each do |(_, stage, value)|
            stage_counts[stage] += 1
            revenue += value.to_i if stage == 'pagamento_efetuado'
          end
        end
        { channel: canal, code: code, stages: TrackingEvent::STAGES.index_with { |s| stage_counts[s] }, revenue_cents: revenue }
      end
      platform = ad_scope&.group(:platform, :campaign_id, :campaign_name)
                          &.pluck(:platform, :campaign_id, :campaign_name, Arel.sql('sum(spend_cents)'), Arel.sql('sum(impressions)'),
                                  Arel.sql('sum(clicks)'), Arel.sql('sum(conversations)'))
      {
        codes: codes.sort_by { |c| -c[:stages]['conversa_iniciada'] },
        ad_campaigns: Array(platform).map do |p|
          { platform: p[0], campaign_id: p[1], campaign_name: p[2], spend_cents: p[3].to_i, impressions: p[4].to_i,
            clicks: p[5].to_i, conversations: p[6].to_i }
        end
      }
    end

    private

    def filter_channel(scope)
      canal = Arel.sql("custom_attributes->>'origem_canal'")
      case @channel
      when 'todos' then scope
      when 'pago' then scope.where(canal => Tracking::Attribution::PAID)
      when 'organico' then scope.where("custom_attributes->>'origem_canal' IS NULL OR custom_attributes->>'origem_canal' = 'organico'")
      else scope.where(canal => @channel)
      end
    end

    def ad_scope
      platforms = case @channel
                  when 'meta', 'google' then [@channel]
                  when 'pago', 'todos' then TrackingAdMetric::PLATFORMS
                  end
      return nil unless platforms

      TrackingAdMetric.where(platform: platforms, date: @from..@to)
    end

    def ad_totals
      scope = ad_scope
      return nil if scope.nil? || !scope.exists?

      s = scope.pick(Arel.sql('sum(spend_cents)'), Arel.sql('sum(impressions)'), Arel.sql('sum(clicks)'), Arel.sql('sum(conversations)'))
      { spend_cents: s[0].to_i, impressions: s[1].to_i, clicks: s[2].to_i, platform_conversations: s[3].to_i }
    end

    def by_channel
      Contact.where(id: contact_ids).group(Arel.sql("coalesce(custom_attributes->>'origem_canal', 'organico')")).count
    end

    def pct(value, base)
      base.to_i.positive? ? (value.to_f * 100 / base).round(1) : nil
    end

    def div(cents, count)
      count.to_i.positive? ? (cents.to_i / count.to_i) : nil
    end
  end
end
