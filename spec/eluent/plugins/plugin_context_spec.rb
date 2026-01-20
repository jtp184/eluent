# frozen_string_literal: true

# rubocop:disable Lint/EmptyBlock -- Empty blocks are intentional test fixtures
RSpec.describe Eluent::Plugins::PluginContext do
  let(:hooks_manager) { Eluent::Plugins::Hooks.new }
  let(:registry) { Eluent::Plugins::PluginRegistry.new }
  let(:context) do
    registry.register('test-plugin')
    described_class.new(name: 'test-plugin', hooks_manager: hooks_manager, registry: registry)
  end

  describe 'hook registration methods' do
    %i[before_create after_create before_close after_close
       before_update after_update on_status_change on_sync].each do |hook_name|
      describe "##{hook_name}" do
        it 'registers the hook' do
          context.public_send(hook_name) { |_ctx| }

          expect(hooks_manager.registered?(hook_name)).to be true
        end

        it 'accepts priority option' do
          context.public_send(hook_name, priority: 50) { |_ctx| }

          entry = hooks_manager.entries_for(hook_name).first
          expect(entry.priority).to eq(50)
        end

        it 'raises error without block' do
          expect do
            context.public_send(hook_name)
          end.to raise_error(Eluent::Plugins::InvalidPluginError, /Hook handler required/)
        end

        it 'records hook in registry' do
          context.public_send(hook_name) { |_ctx| }

          info = registry['test-plugin']
          expect(info.hooks[hook_name]).not_to be_empty
        end
      end
    end
  end

  describe '#command' do
    it 'registers a custom command' do
      context.command('my-cmd', description: 'My custom command') { |_ctx| }

      cmd = registry.find_command('my-cmd')
      expect(cmd[:description]).to eq('My custom command')
      expect(cmd[:plugin]).to eq('test-plugin')
    end

    it 'raises error without block' do
      expect do
        context.command('my-cmd')
      end.to raise_error(Eluent::Plugins::InvalidPluginError, /Command handler required/)
    end
  end

  describe '#register_issue_type' do
    it 'registers a new issue type' do
      context.register_issue_type(:custom_type, abstract: true)

      type = Eluent::Models::IssueType[:custom_type]
      expect(type.name).to eq(:custom_type)
      expect(type.abstract).to be true
    end

    it 'records extension in registry' do
      context.register_issue_type(:custom_type)

      info = registry['test-plugin']
      expect(info.extensions[:issue_types]).to include(:custom_type)
    end
  end

  describe '#register_status_type' do
    it 'registers a new status type' do
      context.register_status_type(:custom_status, from: %i[open], to: %i[closed])

      status = Eluent::Models::Status[:custom_status]
      expect(status.name).to eq(:custom_status)
      expect(status.from).to eq(%i[open])
      expect(status.to).to eq(%i[closed])
    end

    it 'records extension in registry' do
      context.register_status_type(:custom_status)

      info = registry['test-plugin']
      expect(info.extensions[:status_types]).to include(:custom_status)
    end
  end

  describe '#register_dependency_type' do
    it 'registers a new dependency type' do
      context.register_dependency_type(:custom_dep, blocking: false)

      dep_type = Eluent::Models::DependencyType[:custom_dep]
      expect(dep_type.name).to eq(:custom_dep)
      expect(dep_type.blocking).to be false
    end

    it 'records extension in registry' do
      context.register_dependency_type(:custom_dep)

      info = registry['test-plugin']
      expect(info.extensions[:dependency_types]).to include(:custom_dep)
    end
  end
end
# rubocop:enable Lint/EmptyBlock
