# frozen_string_literal: true

RSpec.describe Eluent::Lifecycle::Transition do
  describe Eluent::Lifecycle::InvalidTransitionError do
    it 'stores transition details' do
      error = described_class.new(from_status: :open, to_status: :invalid, allowed: %i[closed blocked])
      expect(error.from_status).to eq(:open)
      expect(error.to_status).to eq(:invalid)
      expect(error.allowed).to eq(%i[closed blocked])
    end

    it 'formats the message' do
      error = described_class.new(from_status: :open, to_status: :invalid, allowed: %i[closed blocked])
      expect(error.message).to include('open')
      expect(error.message).to include('invalid')
      expect(error.message).to include('closed')
    end
  end

  describe '.valid?' do
    context 'from open status' do
      it 'allows transition to in_progress' do
        expect(described_class.valid?(from: :open, to: :in_progress)).to be true
      end

      it 'allows transition to blocked' do
        expect(described_class.valid?(from: :open, to: :blocked)).to be true
      end

      it 'allows transition to deferred' do
        expect(described_class.valid?(from: :open, to: :deferred)).to be true
      end

      it 'allows transition to closed' do
        expect(described_class.valid?(from: :open, to: :closed)).to be true
      end

      it 'allows transition to discard' do
        expect(described_class.valid?(from: :open, to: :discard)).to be true
      end

      it 'does not allow transition to open (same status)' do
        expect(described_class.valid?(from: :open, to: :open)).to be false
      end
    end

    context 'from closed status' do
      it 'allows reopening to open' do
        expect(described_class.valid?(from: :closed, to: :open)).to be true
      end

      it 'allows transition to discard' do
        expect(described_class.valid?(from: :closed, to: :discard)).to be true
      end

      it 'does not allow transition to in_progress' do
        expect(described_class.valid?(from: :closed, to: :in_progress)).to be false
      end

      it 'does not allow transition to blocked' do
        expect(described_class.valid?(from: :closed, to: :blocked)).to be false
      end
    end

    context 'from discard status' do
      it 'allows restore to open' do
        expect(described_class.valid?(from: :discard, to: :open)).to be true
      end

      it 'allows transition to closed' do
        expect(described_class.valid?(from: :discard, to: :closed)).to be true
      end

      it 'does not allow transition to in_progress' do
        expect(described_class.valid?(from: :discard, to: :in_progress)).to be false
      end
    end

    context 'with Status objects' do
      it 'accepts Status objects' do
        from = Eluent::Models::Status[:open]
        to = Eluent::Models::Status[:closed]
        expect(described_class.valid?(from: from, to: to)).to be true
      end
    end

    context 'with string statuses' do
      it 'accepts string statuses' do
        expect(described_class.valid?(from: 'open', to: 'closed')).to be true
      end
    end

    context 'with invalid from status' do
      it 'returns false' do
        expect(described_class.valid?(from: :invalid, to: :open)).to be false
      end
    end
  end

  describe '.validate!' do
    context 'when transition is valid' do
      it 'returns true' do
        expect(described_class.validate!(from: :open, to: :closed)).to be true
      end
    end

    context 'when transition is invalid' do
      it 'raises InvalidTransitionError' do
        expect do
          described_class.validate!(from: :closed, to: :in_progress)
        end.to raise_error(Eluent::Lifecycle::InvalidTransitionError)
      end

      it 'includes allowed transitions in error' do
        expect do
          described_class.validate!(from: :closed, to: :in_progress)
        end.to raise_error do |error|
          expect(error.allowed).to eq(%i[open discard])
        end
      end
    end
  end

  describe '.allowed_transitions' do
    it 'returns allowed transitions from open' do
      allowed = described_class.allowed_transitions(from: :open)
      expect(allowed).to contain_exactly(:in_progress, :blocked, :deferred, :closed, :discard)
    end

    it 'returns allowed transitions from closed' do
      allowed = described_class.allowed_transitions(from: :closed)
      expect(allowed).to contain_exactly(:open, :discard)
    end

    it 'returns allowed transitions from discard' do
      allowed = described_class.allowed_transitions(from: :discard)
      expect(allowed).to contain_exactly(:open, :closed)
    end

    it 'returns empty array for invalid status' do
      allowed = described_class.allowed_transitions(from: :invalid)
      expect(allowed).to be_empty
    end
  end
end
