# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::PhoneNumberNormalizer do
  describe '.call' do
    subject(:normalized) { described_class.call(input) }

    context 'with blank input' do
      [nil, '', '   '].each do |blank|
        context "when input is #{blank.inspect}" do
          let(:input) { blank }

          it { is_expected.to be_nil }
        end
      end
    end

    context 'with Brazilian numbers (+55)' do
      context 'when DDD >= 31 (mobile with extra 9)' do
        # DDD 74, 13 digits already carry the nono dígito: it is kept.
        let(:input) { '5574999879409' }

        it 'keeps the 9' do
          expect(normalized).to eq('5574999879409')
        end
      end

      context 'when DDD >= 31 arrives without the 9' do
        let(:input) { '557499879409' }

        it 'restores the 9 to 13 digits' do
          expect(normalized).to eq('5574999879409')
        end
      end

      context 'when DDD < 31 (metro area keeps the 9)' do
        # DDD 11 = São Paulo, the 9 is preserved.
        let(:input) { '5511999879409' }

        it 'keeps the 9 (13 digits)' do
          expect(normalized).to eq('5511999879409')
        end
      end

      context 'with a landline (subscriber starts 2-5)' do
        # 55 74 3244-8864 -> subscriber "32448864", landline prefix 3.
        let(:input) { '557432448864' }

        it 'keeps 12 digits, no 9' do
          expect(normalized).to eq('557432448864')
        end
      end

      context 'with a mobile whose subscriber starts 7-9' do
        let(:input) { '557482488649' }

        it 'restores the 9' do
          expect(normalized).to eq('5574982488649')
        end
      end

      context 'with cosmetic formatting (+, spaces, parens)' do
        let(:input) { '+55 (74) 99987-9409' }

        it 'cleans and keeps the 9' do
          expect(normalized).to eq('557499879409')
        end
      end
    end

    context 'with Mexican numbers (+52)' do
      context 'when 13 digits with the extra leading 1' do
        let(:input) { '5215512345678' }

        it 'drops the extra digit to 12' do
          expect(normalized).to eq('525512345678')
        end
      end

      context 'when already 12 digits' do
        let(:input) { '525512345678' }

        it 'is left unchanged' do
          expect(normalized).to eq('525512345678')
        end
      end
    end

    context 'with Argentine numbers (+54)' do
      context 'when 13 digits with the extra leading 9' do
        let(:input) { '5491123456789' }

        it 'drops the extra digit to 12' do
          expect(normalized).to eq('541123456789')
        end
      end
    end

    context 'with other countries' do
      # US +1 number — no special casing, only cosmetic cleanup.
      let(:input) { '+1 (415) 555-2671' }

      it 'returns digits unchanged' do
        expect(normalized).to eq('14155552671')
      end
    end

    context 'idempotency' do
      it 'normalizing twice yields the same result' do
        once = described_class.call('557499879409')
        twice = described_class.call(once)
        expect(twice).to eq(once)
        expect(once).to eq('5574999879409')
      end
    end
  end
end
