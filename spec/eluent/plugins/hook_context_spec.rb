# frozen_string_literal: true

RSpec.describe Eluent::Plugins::HookContext do
  let(:atom) do
    Eluent::Models::Atom.new(
      id: 'test-123',
      title: 'Test Item',
      priority: 1
    )
  end
  let(:repo) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:context) { described_class.new(item: atom, repo: repo, event: :before_create) }

  describe '#initialize' do
    it 'stores item and repo' do
      expect(context.item).to eq(atom)
      expect(context.repo).to eq(repo)
    end

    it 'freezes changes and metadata' do
      ctx = described_class.new(
        item: atom,
        repo: repo,
        changes: { status: { from: :open, to: :closed } },
        metadata: { user: 'test' }
      )

      expect(ctx.changes).to be_frozen
      expect(ctx.metadata).to be_frozen
    end
  end

  describe '#halt!' do
    it 'raises HookAbortError' do
      expect { context.halt!('Validation failed') }.to raise_error(
        Eluent::Plugins::HookAbortError,
        'Validation failed'
      )
    end

    it 'marks context as halted' do
      begin
        context.halt!('Stopped')
      rescue Eluent::Plugins::HookAbortError
        # Expected - halt! raises after setting state
      end

      expect(context.halted?).to be true
      expect(context.halt_reason).to eq('Stopped')
    end

    it 'raises with default message when no reason provided' do
      expect { context.halt! }.to raise_error(
        Eluent::Plugins::HookAbortError,
        'Operation halted by plugin'
      )
    end
  end

  describe '#[]' do
    it 'returns item field value' do
      expect(context[:title]).to eq('Test Item')
      expect(context[:priority]).to eq(1)
    end

    it 'returns nil for unknown fields' do
      expect(context[:unknown_field]).to be_nil
    end

    it 'returns nil when item is nil' do
      ctx = described_class.new(item: nil, repo: repo)
      expect(ctx[:title]).to be_nil
    end
  end

  describe '#before_hook?' do
    it 'returns true for before events' do
      ctx = described_class.new(item: atom, repo: repo, event: :before_create)
      expect(ctx.before_hook?).to be true
    end

    it 'returns false for after events' do
      ctx = described_class.new(item: atom, repo: repo, event: :after_create)
      expect(ctx.before_hook?).to be false
    end
  end

  describe '#after_hook?' do
    it 'returns true for after events' do
      ctx = described_class.new(item: atom, repo: repo, event: :after_create)
      expect(ctx.after_hook?).to be true
    end

    it 'returns false for before events' do
      ctx = described_class.new(item: atom, repo: repo, event: :before_create)
      expect(ctx.after_hook?).to be false
    end
  end

  describe '#old_value / #new_value' do
    let(:changes_ctx) do
      described_class.new(
        item: atom,
        repo: repo,
        changes: {
          status: { from: :open, to: :closed },
          priority: { from: 1, to: 0 }
        }
      )
    end

    it 'returns old value from changes' do
      expect(changes_ctx.old_value(:status)).to eq(:open)
      expect(changes_ctx.old_value(:priority)).to eq(1)
    end

    it 'returns new value from changes' do
      expect(changes_ctx.new_value(:status)).to eq(:closed)
      expect(changes_ctx.new_value(:priority)).to eq(0)
    end

    it 'returns nil for unchanged fields' do
      expect(changes_ctx.old_value(:title)).to be_nil
      expect(changes_ctx.new_value(:title)).to be_nil
    end
  end
end
