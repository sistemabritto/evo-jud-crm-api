# Standalone mocks: no Rails boot, DB connection, network or real message delivery.
require 'minitest/autorun'
require 'ostruct'
require 'logger'
require 'time'
require 'thread'
class Object
  def present?; !nil? && self != false && (!respond_to?(:empty?) || !empty?); end
end
class Time
  def self.current; now; end
end
module I18n
  def self.transliterate(s); s.unicode_normalize(:nfd).gsub(/\p{Mn}/,''); end
end
module Rails
  def self.logger; @logger ||= Logger.new(File::NULL); end
  def self.application; OpenStruct.new(config: OpenStruct.new); end
end
module CramerCare
  def self.internal?(c); %w[557182403986 5571982403986].include?(c.contact.phone_number); end
end
class User
  def self.where(*); OpenStruct.new(exists?: false); end
  def self.pluck(*); [['Equipe Adicional', 'Operador Interno']]; end
  def id; 'operator'; end
end
class Label
  def self.find_or_create_by!(**); true; end
end
module Current
  class << self; attr_accessor :user; end
end
module Conversations
  class InvalidHandoffError < StandardError; end
end
load ARGV.fetch(0, File.expand_path('../../../extensions/cramer/failure_handoff.rb', __dir__))
class FakeMessages < Array
  def create!(**attrs); self << attrs; attrs; end
  def where(**attrs)
    matches=select { |m| attrs.all? { |k,v| k == :private ? !!m[k] == v : Array(v).include?(m[k]) } }
    OpenStruct.new(exists?: !matches.empty?)
  end
end
class FakeConversation
  attr_accessor :team, :id, :inbox, :contact, :custom_attributes, :label_list, :status, :assignee_id
  attr_reader :messages
  def initialize
    @id='conversation-mock'; @inbox=OpenStruct.new(channel_type:'Channel::Whatsapp')
    @contact=OpenStruct.new(name:'Pessoa Cliente', email:nil, contact_type:'lead', phone_number:'5500000000000',
      label_list:[], additional_attributes:{}, custom_attributes:{'cramer_failure_notice_audience'=>'lead'})
    @custom_attributes={}; @label_list=[]; @messages=FakeMessages.new; @mutex=Mutex.new; @status=:pending
  end
  def with_lock; @mutex.synchronize { yield }; end
  def update!(**attrs); attrs.each { |k,v| public_send("#{k}=",v) }; end
  def reload; self; end
  def return_to_bot!; @status=:pending; @assignee_id=nil; :returned; end
  prepend CramerFailureHandoff::ReturnToBot
end
class FailureHandoffTest < Minitest::Test
  H=CramerFailureHandoff
  def setup
    @c=FakeConversation.new; @bot=OpenStruct.new(id:H::BOT_IDS.first); Current.user=nil
  end
  def public_messages; @c.messages.reject{|m|m[:private]}; end
  def test_exact_notice_and_failure_variants
    [H::LEGACY,H::DEFAULT,H::NOTICE].each{|s|assert H.failure?(s)}
    refute H.failure?('normal reply')
    assert_equal 'Vou passar o seu atendimento para um dos assistentes do escritório, que vai entrar em contato com você o mais breve possível. 🙏', H::NOTICE
  end
  def test_handoff_and_lifetime_dedup_under_concurrency
    threads=20.times.map { Thread.new { H.handle!(@c,@bot) } }; threads.each(&:value)
    assert_equal 1, public_messages.size
    assert_equal H::NOTICE, public_messages.first[:content]
    assert_equal 20, @c.custom_attributes['cramer_failure_count']
    assert_equal 20, @c.messages.count{|m|m[:private]}
    assert_equal :open, @c.status
    assert_equal H::ANDRE_ID, @c.assignee_id
    assert_includes @c.label_list, 'falha-ia'
    assert H.blocked?(@c)
    assert @c.custom_attributes[H::CLAIM]
  end
  def test_unknown_lead_is_not_positive_classification
    @c.contact.custom_attributes={}
    refute H.public_allowed?(@c)
    H.handle!(@c,@bot)
    assert_empty public_messages
    assert H.blocked?(@c)
    @c.contact.custom_attributes['cramer_failure_notice_audience']='lead'
    H.handle!(@c,@bot)
    assert_empty public_messages
  end
  def test_historical_notice_prevents_new_public_notice
    @c.messages.create!(message_type: :outgoing, private: false, content: H::LEGACY)
    H.handle!(@c,@bot)
    assert_equal 1, public_messages.size
    assert_equal H::LEGACY, public_messages.first[:content]
    assert H.blocked?(@c)
  end
  def test_existing_active_client_label_is_positive_evidence_but_deny_wins
    @c.contact.custom_attributes={}
    @c.contact.label_list=['cliente-ativo']
    assert H.public_allowed?(@c)
    @c.contact.label_list << 'equipe'
    refute H.public_allowed?(@c)
  end
  def test_email_and_other_channels_are_private_only
    %w[Channel::Email Channel::FacebookPage].each do |channel|
      @c=FakeConversation.new; @c.inbox.channel_type=channel
      H.handle!(@c,@bot)
      assert_empty public_messages
      assert @c.messages.all?{|m|m[:private]}
    end
  end
  def test_staff_and_business_names_are_denied_even_if_marked_lead
    ['Daniel','Anna','Rafael','Marina','André Cramer','Equipe Adicional','Operador Interno','Vivo Comunica','Banco ABC','Loja Central'].each do |name|
      @c.contact.name=name
      refute H.public_allowed?(@c), name
    end
  end
  def test_deny_metadata_and_optout_override_positive_classification
    %w[is_business verified automatic internal equipe nao_contatar].each do |key|
      @c.contact.custom_attributes={'cramer_failure_notice_audience'=>'lead',key=>true}
      refute H.public_allowed?(@c), key
    end
    @c.contact.custom_attributes={'cramer_failure_notice_audience'=>'lead'}
    H::DENY_LABELS.each do |label|
      @c.contact.label_list=[label]; refute H.public_allowed?(@c), label
    end
  end
  def test_blocked_phone_remains_blocked
    %w[557182403986 5571982403986].each do |phone|
      @c.contact.phone_number=phone; refute H.public_allowed?(@c)
    end
  end
  def test_only_explicit_human_return_clears_block_without_clearing_claim
    H.handle!(@c,@bot)
    @c.update!(status: :pending)
    assert H.blocked?(@c)
    assert_raises(Conversations::InvalidHandoffError){@c.return_to_bot!}
    @c.status=:open
    Current.user=User.new
    assert_equal :returned, @c.return_to_bot!
    refute H.blocked?(@c)
    assert @c.custom_attributes[H::CLAIM]
    H.handle!(@c,@bot)
    assert_equal 1, public_messages.size
  end
  def test_target_scope
    H::BOT_IDS.each{|id|assert H.target?(OpenStruct.new(id:id),@c)}
    refute H.target?(OpenStruct.new(id:'other'),@c)
    @c.inbox.channel_type='Channel::Email'
    assert H.target?(OpenStruct.new(id:H::EMAIL_BOT_ID),@c)
  end
end
class Message
  class << self; attr_accessor :mock; end
  def self.find(_); mock; end
end
class FakeDeliveryMessage
  attr_accessor :content_attributes, :content, :sender_type, :sender_id, :conversation, :sender
  def initialize(c)
    @conversation=c; @sender_type='AgentBot'; @sender_id=CramerFailureHandoff::BOT_IDS.first
    @sender=OpenStruct.new(id:@sender_id); @content='Normal'; @content_attributes={}; @mutex=Mutex.new
  end
  def with_lock; @mutex.synchronize{yield}; end
  def update_columns(**attrs); @content_attributes=attrs[:content_attributes]; end
end
class FakeDelivery
  attr_accessor :calls, :fail
  def initialize; @calls=0; end
  def perform(_)
    @calls+=1
    raise 'mock ambiguous network error' if @fail
  end
  prepend CramerFailureHandoff::Delivery
end
class DeliveryTest < Minitest::Test
  H=CramerFailureHandoff
  def setup
    @c=FakeConversation.new; @m=FakeDeliveryMessage.new(@c); Message.mock=@m; @job=FakeDelivery.new
  end
  def test_queued_reply_is_blocked
    @c.custom_attributes[H::BLOCK]=true; @job.perform('mock'); assert_equal 0,@job.calls
  end
  def test_duplicate_delivery_jobs_only_attempt_once
    @m.content_attributes[H::NOTICE_KEY]=true; @m.content=H::NOTICE
    20.times.map{Thread.new{@job.perform('mock')}}.each(&:value)
    assert_equal 1,@job.calls
    assert @m.content_attributes['cramer_failure_delivery_attempted_at']
  end
  def test_ambiguous_delivery_error_is_not_retried
    @m.content_attributes[H::NOTICE_KEY]=true; @job.fail=true
    assert_raises(RuntimeError){@job.perform('mock')}
    @job.perform('mock'); assert_equal 1,@job.calls
  end
  def test_audience_is_rechecked_at_delivery
    @m.content_attributes[H::NOTICE_KEY]=true; @c.contact.name='Daniel'
    @job.perform('mock'); assert_equal 0,@job.calls
  end
  def test_legacy_notice_already_queued_is_intercepted
    @m.content=H::LEGACY; @job.perform('mock')
    assert_equal 0,@job.calls
    assert H.blocked?(@c)
    assert_equal H::NOTICE,@c.messages.last[:content]
  end
end
class FakePostback
  attr_reader :params, :rendered, :super_called
  def initialize(c,bot,content)
    @conversation=c; @bot=bot; @params={conversation_display_id:1,content:content}
  end
  def find_active_agent_bot(_); @bot; end
  def render(**args); @rendered=args; end
  def postback; @super_called=true; end
  prepend CramerFailureHandoff::Postback
end
class Conversation
  class << self; attr_accessor :mock; end
  def self.find_by(**); mock; end
end
class PostbackTest < Minitest::Test
  def test_failure_handled_before_existing_eligibility_and_normal_reply_discarded
    c=FakeConversation.new; Conversation.mock=c
    bot=OpenStruct.new(id:CramerFailureHandoff::BOT_IDS.last)
    request=FakePostback.new(c,bot,CramerFailureHandoff::LEGACY); request.postback
    assert_equal 'human_handoff',request.rendered[:json][:status]
    refute request.super_called
    late=FakePostback.new(c,bot,'late AI reply'); late.postback
    assert_equal 'discarded',late.rendered[:json][:status]
    refute late.super_called
  end
end
