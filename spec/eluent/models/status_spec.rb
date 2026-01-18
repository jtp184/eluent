# frozen_string_literal: true

RSpec.describe Eluent::Models::Status do
  it_behaves_like 'a value object with extendable collection',
                  described_class,
                  described_class.defaults

  describe 'default statuses' do
    it 'includes open' do
      expect(described_class[:open]).to be_a(described_class)
    end

    it 'includes in_progress' do
      expect(described_class[:in_progress]).to be_a(described_class)
    end

    it 'includes blocked' do
      expect(described_class[:blocked]).to be_a(described_class)
    end

    it 'includes deferred' do
      expect(described_class[:deferred]).to be_a(described_class)
    end

    it 'includes closed' do
      expect(described_class[:closed]).to be_a(described_class)
    end

    it 'includes discard' do
      expect(described_class[:discard]).to be_a(described_class)
    end
  end

  describe '#initialize' do
    it 'sets the name' do
      status = described_class.new(name: :custom)
      expect(status.name).to eq(:custom)
    end

    it 'defaults from and to to empty arrays' do
      status = described_class.new(name: :custom)
      expect(status.from).to eq([])
      expect(status.to).to eq([])
    end

    it 'accepts from and to parameters' do
      status = described_class.new(name: :custom, from: [:open], to: [:closed])
      expect(status.from).to eq([:open])
      expect(status.to).to eq([:closed])
    end
  end

  describe 'discard status' do
    subject(:discard) { described_class[:discard] }

    it 'allows transition from closed' do
      expect(discard.from).to include(:closed)
    end
  end
end
