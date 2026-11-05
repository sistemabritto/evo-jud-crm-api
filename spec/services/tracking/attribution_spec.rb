# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Tracking::Attribution do
  describe '.parse' do
    {
      'Olá! Vi o anúncio sobre inventário. [INV1]' => ['meta', 'inv1', 'inventario'],
      'Olá! [GINV2]' => ['google', 'ginv2', 'inventario'],
      'Vim pelo site [SGER1]' => ['site', 'sger1', 'geral'],
      'Post [PDIV1]' => ['postiz', 'pdiv1', 'divorcio'],
      'DM [OIMO3]' => ['openreply', 'oimo3', 'imobiliario'],
      'Aposentadoria [PRE1]' => ['meta', 'pre1', 'previdenciario'],
      'Instagram [IG1]' => ['instagram', 'ig1', nil]
    }.each do |text, (channel, campaign, area)|
      it "reads #{text.inspect}" do
        expect(described_class.parse(text)).to include(channel: channel, campaign: campaign, area: area)
      end
    end

    it 'reads the site click reference after the code' do
      expect(described_class.parse('Olá! [GINV1-AB12C]')).to include(channel: 'google', campaign: 'ginv1', ref: 'AB12C')
    end

    it 'ignores text without a trailing code' do
      expect(described_class.parse('Olá, quero saber do meu processo')).to be_nil
    end

    it 'treats a click-to-WhatsApp referral as Meta even without code' do
      origin = described_class.parse('Olá', { 'sourceType' => 'ad', 'sourceID' => '123', 'ctwaClid' => 'abc' })
      expect(origin).to include(channel: 'meta', ad_id: '123', ctwa_clid: 'abc', campaign: 'ad-123')
    end
  end

  describe '.link' do
    it 'builds a wa.me link with the channel code' do
      link = described_class.link(number: '+55 71 99705-9693', channel: 'google', area: 'INV')
      expect(link[:code]).to eq('GINV1')
      expect(link[:url]).to start_with('https://wa.me/5571997059693?text=')
      expect(described_class.parse(link[:text])).to include(channel: 'google', campaign: 'ginv1')
    end
  end
end
