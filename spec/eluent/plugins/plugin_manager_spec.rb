# frozen_string_literal: true

# rubocop:disable Lint/EmptyBlock -- Empty blocks are intentional test fixtures
RSpec.describe Eluent::Plugins::PluginManager do
  let(:manager) { described_class.new }

  after { manager.reset! }

  describe '#register' do
    it 'registers a plugin' do
      manager.register('test-plugin')

      expect(manager.registry.registered?('test-plugin')).to be true
    end

    it 'evaluates the block in plugin context' do
      manager.register('test-plugin') do
        before_create { |_ctx| }
      end

      expect(manager.hooks.registered?(:before_create)).to be true
    end

    it 'returns plugin info' do
      info = manager.register('test-plugin', path: '/test/path.rb')

      expect(info.name).to eq('test-plugin')
      expect(info.path).to eq('/test/path.rb')
    end
  end

  describe '#invoke_hook' do
    let(:mock_context) { instance_double(Eluent::Plugins::HookContext) }

    it 'invokes hooks through hooks manager' do
      call_count = 0
      manager.register('test-plugin') do
        before_create { |_ctx| call_count += 1 }
      end

      manager.invoke_hook(:before_create, mock_context)

      expect(call_count).to eq(1)
    end

    it 'returns hook result' do
      manager.register('test-plugin') do
        before_create { |_ctx| }
      end

      result = manager.invoke_hook(:before_create, mock_context)

      expect(result.success).to be true
    end
  end

  describe '#create_context' do
    let(:atom) { Eluent::Models::Atom.new(id: 'test-123', title: 'Test') }
    let(:repo) { instance_double(Eluent::Storage::JsonlRepository) }

    it 'creates a hook context' do
      context = manager.create_context(
        item: atom,
        repo: repo,
        event: :before_create,
        changes: { title: { from: 'Old', to: 'New' } },
        metadata: { user: 'test' }
      )

      expect(context).to be_a(Eluent::Plugins::HookContext)
      expect(context.item).to eq(atom)
      expect(context.repo).to eq(repo)
      expect(context.event).to eq(:before_create)
      expect(context.changes).to eq({ title: { from: 'Old', to: 'New' } })
      expect(context.metadata).to eq({ user: 'test' })
    end
  end

  describe '#find_command' do
    it 'finds registered commands' do
      manager.register('test-plugin') do
        command('custom', description: 'Custom cmd') { |_ctx| }
      end

      cmd = manager.find_command('custom')

      expect(cmd[:description]).to eq('Custom cmd')
    end

    it 'returns nil for unknown command' do
      expect(manager.find_command('unknown')).to be_nil
    end
  end

  describe '#all_commands' do
    it 'returns all registered commands' do
      manager.register('plugin-a') do
        command('cmd1') { |_| }
      end
      manager.register('plugin-b') do
        command('cmd2') { |_| }
      end

      commands = manager.all_commands

      expect(commands.keys).to contain_exactly('cmd1', 'cmd2')
    end
  end

  describe '#all_plugins' do
    it 'returns all registered plugins' do
      manager.register('plugin-a')
      manager.register('plugin-b')

      plugins = manager.all_plugins

      expect(plugins.map(&:name)).to contain_exactly('plugin-a', 'plugin-b')
    end
  end

  describe '#loaded?' do
    it 'returns false initially' do
      expect(manager.loaded?).to be false
    end

    it 'returns true after load_all!' do
      manager.load_all!(load_gems: false)
      expect(manager.loaded?).to be true
    end
  end

  describe '#load_all!' do
    it 'only loads once' do
      manager.load_all!(load_gems: false)
      manager.load_all!(load_gems: false)

      # No error means it worked
      expect(manager.loaded?).to be true
    end
  end

  describe '#reset!' do
    it 'clears all state' do
      manager.register('test-plugin') do
        before_create { |_ctx| }
      end

      manager.reset!

      expect(manager.all_plugins).to be_empty
      expect(manager.hooks.registered?(:before_create)).to be false
      expect(manager.loaded?).to be false
    end
  end
end

RSpec.describe Eluent::Plugins do
  describe '.manager' do
    it 'returns a PluginManager instance' do
      expect(described_class.manager).to be_a(Eluent::Plugins::PluginManager)
    end

    it 'returns the same instance on multiple calls' do
      manager1 = described_class.manager
      manager2 = described_class.manager

      expect(manager1).to be(manager2)
    end
  end

  describe '.register' do
    after { described_class.reset! }

    it 'registers a plugin on the global manager' do
      described_class.register('module-level-plugin') do
        before_create { |_ctx| }
      end

      expect(described_class.manager.registry.registered?('module-level-plugin')).to be true
    end
  end

  describe '.reset!' do
    it 'creates a new manager' do
      old_manager = described_class.manager
      described_class.reset!
      new_manager = described_class.manager

      expect(new_manager).not_to be(old_manager)
    end
  end
end
# rubocop:enable Lint/EmptyBlock
