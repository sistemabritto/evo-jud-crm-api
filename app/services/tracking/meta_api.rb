# evo-jud-crm: chamadas à Graph API do Meta (insights de anúncios e Conversions API).
require 'net/http'

module Tracking
  module MetaApi
    VERSION = 'v21.0'.freeze
    CAPI_EVENTS = {
      'conversa_iniciada' => 'Lead', 'link_agendamento_enviado' => 'Contact', 'reuniao_agendada' => 'Schedule',
      'contrato_assinado' => 'SubmitApplication', 'pagamento_efetuado' => 'Purchase'
    }.freeze
    CONVERSATION_ACTION = 'onsite_conversion.messaging_conversation_started_7d'.freeze

    module_function

    def request(method, path, params: {}, body: nil)
      uri = URI("https://graph.facebook.com/#{VERSION}/#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      if body
        req['Content-Type'] = 'application/json'
        req.body = body.to_json
      end
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |h| h.request(req) }
      json = JSON.parse(res.body.presence || '{}')
      raise "Meta API #{res.code}: #{json.dig('error', 'message').to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)

      json
    end

    # Insights diários por campanha dos últimos `days` dias, gravados em tracking_ad_metrics.
    def sync_insights!(days: 35)
      account = Tracking::Config.get('TRACKING_META_AD_ACCOUNT_ID').to_s.delete_prefix('act_')
      token = Tracking::Config.get('TRACKING_META_ACCESS_TOKEN_SECRET')
      raise 'Meta não configurado' if account.blank? || token.blank?

      params = {
        access_token: token, level: 'campaign', time_increment: 1, limit: 500,
        fields: 'campaign_id,campaign_name,spend,impressions,clicks,inline_link_clicks,actions',
        time_range: { since: (Date.current - days).iso8601, until: Date.current.iso8601 }.to_json
      }
      path = "act_#{account}/insights"
      count = 0
      loop do
        page = request(:get, path, params: params)
        Array(page['data']).each do |row|
          conv = Array(row['actions']).find { |a| a['action_type'] == CONVERSATION_ACTION }
          upsert_metric('meta', row['date_start'], row['campaign_id'], row['campaign_name'],
                        spend_cents: (row['spend'].to_f * 100).round, impressions: row['impressions'].to_i,
                        clicks: (row['inline_link_clicks'] || row['clicks']).to_i, conversations: conv ? conv['value'].to_i : 0)
          count += 1
        end
        after = page.dig('paging', 'cursors', 'after')
        break if after.blank? || page.dig('paging', 'next').blank?

        params = params.merge(after: after)
      end
      GlobalConfig.set('TRACKING_META_LAST_SYNC_AT', Time.current.iso8601) rescue nil # rubocop:disable Style/RescueModifier
      count
    end

    def upsert_metric(platform, date, campaign_id, campaign_name, spend_cents:, impressions:, clicks:, conversations: 0)
      m = TrackingAdMetric.find_or_initialize_by(platform: platform, date: date, campaign_id: campaign_id.to_s)
      m.update!(campaign_name: campaign_name, spend_cents: spend_cents, impressions: impressions, clicks: clicks,
                conversations: conversations)
    end

    def sha(value)
      Digest::SHA256.hexdigest(value.to_s.strip.downcase)
    end

    # Conversions API. Com ctwa_clid + WABA usa o modo business_messaging (atribuição do anúncio de
    # WhatsApp); sem isso, system_generated com telefone/e-mail em hash (correspondência pelo Meta).
    def send_capi!(event)
      pixel = Tracking::Config.get('TRACKING_META_PIXEL_ID')
      token = Tracking::Config.capi_token
      contact = event.contact
      attrs = contact.custom_attributes || {}
      user_data = { external_id: [sha(contact.id)] }
      phone = contact.phone_number.to_s.gsub(/\D/, '')
      user_data[:ph] = [sha(phone)] if phone.present?
      user_data[:em] = [sha(contact.email)] if contact.email.present?
      data = { event_name: CAPI_EVENTS.fetch(event.stage), event_time: event.occurred_at.to_i, event_id: event.id,
               user_data: user_data, custom_data: { origem: attrs['origem_canal'], campanha: attrs['origem_campanha'] }.compact }
      waba = Tracking::Config.get('TRACKING_META_WABA_ID')
      if attrs['origem_ctwa_clid'].present? && waba.present?
        data[:action_source] = 'business_messaging'
        data[:messaging_channel] = 'whatsapp'
        user_data[:ctwa_clid] = attrs['origem_ctwa_clid']
        user_data[:whatsapp_business_account_id] = waba
      else
        data[:action_source] = 'system_generated'
      end
      data[:custom_data].merge!(currency: 'BRL', value: event.value_cents.to_i / 100.0) if event.stage == 'pagamento_efetuado'
      body = { data: [data] }
      test = Tracking::Config.get('TRACKING_META_TEST_EVENT_CODE')
      body[:test_event_code] = test if test.present?
      request(:post, "#{pixel}/events", params: { access_token: token }, body: body)
      event.update!(capi_sent_at: Time.current)
    end
  end
end
