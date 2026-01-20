# frozen_string_literal: true

# rubocop:disable Lint/EmptyBlock -- Empty blocks are intentional test fixtures
RSpec.describe Eluent::Plugins::PluginRegistry do
  let(:registry) { described_class.new }

  describe '#register' do
    it 'registers a plugin' do
      info = registry.register('test-plugin', path: '/path/to/plugin.rb')

      expect(info.name).to eq('test-plugin')
      expect(info.path).to eq('/path/to/plugin.rb')
      expect(info.loaded_at).to be_a(Time)
    end

    it 'raises error for duplicate registration' do
      registry.register('test-plugin')

      expect do
        registry.register('test-plugin')
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /already registered/)
    end
  end

  describe '#unregister' do
    it 'removes a registered plugin' do
      registry.register('test-plugin')

      expect(registry.unregister('test-plugin')).to be true
      expect(registry.registered?('test-plugin')).to be false
    end

    it 'returns false for unknown plugin' do
      expect(registry.unregister('unknown')).to be false
    end

    it 'removes associated commands' do
      registry.register('test-plugin')
      registry.register_command('custom', plugin_name: 'test-plugin') { |_| }

      registry.unregister('test-plugin')

      expect(registry.find_command('custom')).to be_nil
    end
  end

  describe '#[]' do
    it 'returns plugin info' do
      registry.register('test-plugin')

      info = registry['test-plugin']

      expect(info).to be_a(described_class::PluginInfo)
      expect(info.name).to eq('test-plugin')
    end

    it 'returns nil for unknown plugin' do
      expect(registry['unknown']).to be_nil
    end
  end

  describe '#registered?' do
    it 'returns true for registered plugins' do
      registry.register('test-plugin')
      expect(registry.registered?('test-plugin')).to be true
    end

    it 'returns false for unknown plugins' do
      expect(registry.registered?('unknown')).to be false
    end
  end

  describe '#all' do
    it 'returns all registered plugins' do
      registry.register('plugin-a')
      registry.register('plugin-b')

      all = registry.all

      expect(all.size).to eq(2)
      expect(all.map(&:name)).to contain_exactly('plugin-a', 'plugin-b')
    end
  end

  describe '#names' do
    it 'returns all plugin names' do
      registry.register('plugin-a')
      registry.register('plugin-b')

      expect(registry.names).to contain_exactly('plugin-a', 'plugin-b')
    end
  end

  describe '#register_command' do
    before { registry.register('test-plugin') }

    it 'registers a command' do
      registry.register_command('custom', plugin_name: 'test-plugin', description: 'Custom command') { |_| }

      cmd = registry.find_command('custom')

      expect(cmd[:description]).to eq('Custom command')
      expect(cmd[:plugin]).to eq('test-plugin')
    end

    it 'raises error for unknown plugin' do
      expect do
        registry.register_command('custom', plugin_name: 'unknown') { |_| }
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /Unknown plugin/)
    end

    it 'raises error for duplicate command' do
      registry.register('other-plugin')
      registry.register_command('custom', plugin_name: 'test-plugin') { |_| }

      expect do
        registry.register_command('custom', plugin_name: 'other-plugin') { |_| }
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /already registered/)
    end

    it 'tracks command in plugin info' do
      registry.register_command('custom', plugin_name: 'test-plugin') { |_| }

      info = registry['test-plugin']
      expect(info.command_names).to include('custom')
    end
  end

  describe '#find_command' do
    it 'returns nil for unknown command' do
      expect(registry.find_command('unknown')).to be_nil
    end
  end

  describe '#all_commands' do
    it 'returns all commands' do
      registry.register('test-plugin')
      registry.register_command('cmd1', plugin_name: 'test-plugin') { |_| }
      registry.register_command('cmd2', plugin_name: 'test-plugin') { |_| }

      commands = registry.all_commands

      expect(commands.keys).to contain_exactly('cmd1', 'cmd2')
    end
  end

  describe '#record_hook' do
    it 'records hook registration' do
      registry.register('test-plugin')
      registry.record_hook('test-plugin', :before_create)

      info = registry['test-plugin']
      expect(info.hooks[:before_create].size).to eq(1)
    end

    it 'ignores unknown plugins' do
      expect { registry.record_hook('unknown', :before_create) }.not_to raise_error
    end
  end

  describe '#record_extension' do
    it 'records type extension' do
      registry.register('test-plugin')
      registry.record_extension('test-plugin', :issue_types, :custom_type)

      info = registry['test-plugin']
      expect(info.extensions[:issue_types]).to include(:custom_type)
    end
  end

  describe '#clear!' do
    it 'removes all plugins and commands' do
      registry.register('test-plugin')
      registry.register_command('custom', plugin_name: 'test-plugin') { |_| }

      registry.clear!

      expect(registry.all).to be_empty
      expect(registry.all_commands).to be_empty
    end
  end

  describe Eluent::Plugins::PluginRegistry::PluginInfo do
    let(:info) do
      described_class.new(
        name: 'test',
        path: '/path',
        loaded_at: Time.now.utc,
        hooks: { before_create: [1, 2], after_create: [3] },
        commands: { 'cmd1' => {}, 'cmd2' => {} },
        extensions: { issue_types: [:custom], status_types: [], dependency_types: [] }
      )
    end

    describe '#hook_count' do
      it 'returns total number of hooks' do
        expect(info.hook_count).to eq(3)
      end
    end

    describe '#command_names' do
      it 'returns command names' do
        expect(info.command_names).to contain_exactly('cmd1', 'cmd2')
      end
    end
  end
end
# rubocop:enable Lint/EmptyBlock
