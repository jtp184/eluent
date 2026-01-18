# frozen_string_literal: true

RSpec.describe Eluent::Models::InvalidTransitionError do
  it 'stores transition details' do
    error = described_class.new(from_status: :open, to_status: :invalid, allowed: %i[closed blocked])
    expect(error.from_status).to eq(:open)
    expect(error.to_status).to eq(:invalid)
    expect(error.allowed).to eq(%i[closed blocked])
  end

  it 'formats the message with allowed transitions' do
    error = described_class.new(from_status: :open, to_status: :invalid, allowed: %i[closed blocked])
    expect(error.message).to include('open')
    expect(error.message).to include('invalid')
    expect(error.message).to include('closed')
  end

  it 'handles nil allowed (unrestricted)' do
    error = described_class.new(from_status: :open, to_status: :closed, allowed: nil)
    expect(error.message).to include('any')
  end
end

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

  describe '#can_transition_to?' do
    context 'when to is empty (unrestricted)' do
      subject(:status) { described_class[:open] }

      it 'returns true for any target' do
        expect(status.can_transition_to?(:closed)).to be true
        expect(status.can_transition_to?(:anything)).to be true
      end

      it 'accepts Status objects' do
        expect(status.can_transition_to?(described_class[:closed])).to be true
      end

      it 'accepts strings' do
        expect(status.can_transition_to?('closed')).to be true
      end
    end

    context 'when to has specific values (whitelist)' do
      subject(:status) { described_class.new(name: :restricted, to: %i[open closed]) }

      it 'returns true for allowed targets' do
        expect(status.can_transition_to?(:open)).to be true
        expect(status.can_transition_to?(:closed)).to be true
      end

      it 'returns false for disallowed targets' do
        expect(status.can_transition_to?(:blocked)).to be false
        expect(status.can_transition_to?(:anything)).to be false
      end
    end

    it 'raises ArgumentError for invalid types when restricted' do
      status = described_class.new(name: :restricted, to: %i[open closed])
      expect { status.can_transition_to?(123) }.to raise_error(ArgumentError, /Invalid status type/)
    end
  end

  describe '#can_transition_from?' do
    context 'when from is empty (unrestricted)' do
      subject(:status) { described_class[:open] }

      it 'returns true for any source' do
        expect(status.can_transition_from?(:closed)).to be true
        expect(status.can_transition_from?(:anything)).to be true
      end
    end

    context 'when from has specific values (whitelist)' do
      subject(:status) { described_class[:discard] }

      it 'returns true for allowed sources' do
        expect(status.can_transition_from?(:closed)).to be true
      end

      it 'returns false for disallowed sources' do
        expect(status.can_transition_from?(:open)).to be false
      end
    end
  end

  describe '#allowed_transitions' do
    context 'when to is empty (unrestricted)' do
      it 'returns nil to indicate any transition allowed' do
        status = described_class[:open]
        expect(status.allowed_transitions).to be_nil
      end
    end

    context 'when to has specific values' do
      it 'returns the allowed transitions' do
        status = described_class.new(name: :restricted, to: %i[open closed])
        expect(status.allowed_transitions).to eq(%i[open closed])
      end
    end
  end
end
