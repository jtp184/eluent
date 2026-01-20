# frozen_string_literal: true

# rubocop:disable Lint/EmptyBlock -- Empty blocks are intentional test fixtures
RSpec.describe Eluent::Plugins::HooksManager do
  let(:hooks) { described_class.new }
  let(:mock_context) { instance_double(Eluent::Plugins::HookContext) }

  describe 'LIFECYCLE_HOOKS' do
    it 'defines expected lifecycle hooks' do
      expect(described_class::LIFECYCLE_HOOKS).to include(
        :before_create, :after_create,
        :before_close, :after_close,
        :before_update, :after_update,
        :on_status_change, :on_sync
      )
    end
  end

  describe '#register' do
    it 'registers a hook callback' do
      hooks.register(:before_create, plugin_name: 'test-plugin') { |_ctx| }

      expect(hooks.registered?(:before_create)).to be true
    end

    it 'registers hooks with priority ordering' do
      hooks.register(:before_create, plugin_name: 'low', priority: 200) { |_ctx| 'low' }
      hooks.register(:before_create, plugin_name: 'high', priority: 50) { |_ctx| 'high' }
      hooks.register(:before_create, plugin_name: 'medium', priority: 100) { |_ctx| 'medium' }

      entries = hooks.entries_for(:before_create)
      expect(entries.map(&:plugin_name)).to eq(%w[high medium low])
    end

    it 'raises error for unknown hook name' do
      expect do
        hooks.register(:unknown_hook, plugin_name: 'test') { |_ctx| }
      end.to raise_error(ArgumentError, /Unknown hook/)
    end

    it 'raises error when no callback provided' do
      expect do
        hooks.register(:before_create, plugin_name: 'test')
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /Callback required/)
    end

    it 'returns the created hook entry' do
      entry = hooks.register(:before_create, plugin_name: 'test', priority: 50) { |_ctx| }

      expect(entry).to be_a(described_class::HookEntry)
      expect(entry.plugin_name).to eq('test')
      expect(entry.priority).to eq(50)
    end

    it 'raises error for nil priority' do
      expect do
        hooks.register(:before_create, plugin_name: 'test', priority: nil) { |_ctx| }
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /Integer/)
    end

    it 'raises error for string priority' do
      expect do
        hooks.register(:before_create, plugin_name: 'test', priority: '100') { |_ctx| }
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /Integer/)
    end

    it 'raises error for float priority' do
      expect do
        hooks.register(:before_create, plugin_name: 'test', priority: 100.5) { |_ctx| }
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /Integer/)
    end
  end

  describe '#unregister' do
    it 'removes all hooks for a plugin' do
      hooks.register(:before_create, plugin_name: 'test') { |_ctx| }
      hooks.register(:after_create, plugin_name: 'test') { |_ctx| }
      hooks.register(:before_create, plugin_name: 'other') { |_ctx| }

      hooks.unregister('test')

      expect(hooks.entries_for(:before_create).map(&:plugin_name)).to eq(['other'])
      expect(hooks.entries_for(:after_create)).to be_empty
    end
  end

  describe '#invoke' do
    it 'calls all registered callbacks in priority order' do
      call_order = []

      hooks.register(:before_create, plugin_name: 'first', priority: 50) { |_ctx| call_order << 'first' }
      hooks.register(:before_create, plugin_name: 'second', priority: 100) { |_ctx| call_order << 'second' }

      hooks.invoke(:before_create, mock_context)

      expect(call_order).to eq(%w[first second])
    end

    it 'returns success result when all callbacks complete' do
      hooks.register(:before_create, plugin_name: 'test') { |_ctx| }

      result = hooks.invoke(:before_create, mock_context)

      expect(result.success).to be true
      expect(result.halted).to be false
    end

    it 'returns halted result when callback raises HookAbortError' do
      hooks.register(:before_create, plugin_name: 'aborter') do |_ctx|
        raise Eluent::Plugins::HookAbortError.new('Validation failed', reason: 'Invalid data')
      end

      result = hooks.invoke(:before_create, mock_context)

      expect(result.success).to be false
      expect(result.halted).to be true
      expect(result.reason).to eq('Invalid data')
      expect(result.plugin).to eq('aborter')
    end

    it 'returns failed result when callback raises other error' do
      hooks.register(:before_create, plugin_name: 'broken') { |_ctx| raise StandardError, 'Oops' }

      result = hooks.invoke(:before_create, mock_context)

      expect(result.success).to be false
      expect(result.halted).to be false
      expect(result.reason).to eq('Oops')
      expect(result.plugin).to eq('broken')
    end

    it 'stops execution on first abort' do
      call_order = []

      hooks.register(:before_create, plugin_name: 'first', priority: 50) { |_ctx| call_order << 'first' }
      hooks.register(:before_create, plugin_name: 'aborter', priority: 75) do |_ctx|
        raise Eluent::Plugins::HookAbortError, 'Stop'
      end
      hooks.register(:before_create, plugin_name: 'last', priority: 100) { |_ctx| call_order << 'last' }

      hooks.invoke(:before_create, mock_context)

      expect(call_order).to eq(['first'])
    end

    it 'raises error for unknown hook name' do
      expect do
        hooks.invoke(:unknown_hook, mock_context)
      end.to raise_error(ArgumentError, /Unknown hook/)
    end
  end

  describe '#entries_for' do
    it 'returns a copy of entries for a hook' do
      hooks.register(:before_create, plugin_name: 'test') { |_ctx| }

      entries = hooks.entries_for(:before_create)
      entries.clear

      expect(hooks.entries_for(:before_create).size).to eq(1)
    end
  end

  describe '#all_entries' do
    it 'returns all hooks grouped by name' do
      hooks.register(:before_create, plugin_name: 'test1') { |_ctx| }
      hooks.register(:after_create, plugin_name: 'test2') { |_ctx| }

      all = hooks.all_entries

      expect(all.keys).to include(:before_create, :after_create)
      expect(all[:before_create].size).to eq(1)
      expect(all[:after_create].size).to eq(1)
    end
  end

  describe '#clear!' do
    it 'removes all registered hooks' do
      hooks.register(:before_create, plugin_name: 'test') { |_ctx| }
      hooks.register(:after_create, plugin_name: 'test') { |_ctx| }

      hooks.clear!

      expect(hooks.registered?(:before_create)).to be false
      expect(hooks.registered?(:after_create)).to be false
    end
  end

  describe Eluent::Plugins::HooksManager::HookEntry do
    it 'is sortable by priority' do
      low = described_class.new(plugin_name: 'low', priority: 50, callback: -> {})
      high = described_class.new(plugin_name: 'high', priority: 100, callback: -> {})

      expect([high, low].sort).to eq([low, high])
    end
  end

  describe Eluent::Plugins::HooksManager::HookResult do
    describe '.success' do
      it 'creates a successful result' do
        result = described_class.success
        expect(result.success).to be true
        expect(result.halted).to be false
      end
    end

    describe '.halted' do
      it 'creates a halted result' do
        result = described_class.halted(reason: 'stopped', plugin: 'test')
        expect(result.success).to be false
        expect(result.halted).to be true
        expect(result.reason).to eq('stopped')
      end
    end

    describe '.failed' do
      it 'creates a failed result' do
        result = described_class.failed(reason: 'error', plugin: 'test')
        expect(result.success).to be false
        expect(result.halted).to be false
        expect(result.reason).to eq('error')
      end
    end
  end
end
# rubocop:enable Lint/EmptyBlock
