# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/plugin'

# rubocop:disable Lint/EmptyBlock -- Empty blocks are intentional test fixtures
RSpec.describe Eluent::CLI::Commands::Plugin do
  let(:command) { described_class.new(argv, robot_mode: robot_mode) }
  let(:argv) { [] }
  let(:robot_mode) { false }

  before do
    Eluent::Plugins.reset!
  end

  after do
    Eluent::Plugins.reset!
  end

  describe '#run with list subcommand' do
    let(:argv) { ['list'] }

    context 'with no plugins' do
      it 'returns 0' do
        expect(command.run).to eq(0)
      end

      it 'outputs no plugins message' do
        expect { command.run }.to output(/No plugins loaded/).to_stdout
      end
    end

    context 'with plugins loaded' do
      before do
        Eluent::Plugins.register('test-plugin') do
          before_create { |_ctx| }
        end
      end

      it 'outputs plugin table' do
        expect { command.run }.to output(/test-plugin/).to_stdout
      end
    end

    context 'in robot mode' do
      let(:robot_mode) { true }

      it 'outputs JSON' do
        output = capture_stdout { command.run }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('ok')
        expect(parsed['data']['plugins']).to be_an(Array)
      end
    end
  end

  describe '#run with hooks subcommand' do
    let(:argv) { ['hooks'] }

    context 'with no hooks' do
      it 'returns 0' do
        expect(command.run).to eq(0)
      end

      it 'outputs no hooks message' do
        expect { command.run }.to output(/No hooks registered/).to_stdout
      end
    end

    context 'with hooks registered' do
      before do
        Eluent::Plugins.register('test-plugin') do
          before_create(priority: 50) { |_ctx| }
          after_create { |_ctx| }
        end
      end

      it 'outputs hooks table' do
        expect { command.run }.to output(/before_create.*test-plugin.*50/m).to_stdout
      end
    end

    context 'in robot mode' do
      let(:robot_mode) { true }

      before do
        Eluent::Plugins.register('test-plugin') do
          before_create { |_ctx| }
        end
      end

      it 'outputs JSON with hook data' do
        output = capture_stdout { command.run }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('ok')
        expect(parsed['data']['hooks']).to be_a(Hash)
        expect(parsed['data']['hooks']['before_create']).to be_an(Array)
      end
    end
  end

  describe '#run with unknown subcommand' do
    let(:argv) { ['unknown'] }

    it 'returns error' do
      expect(command.run).to eq(1)
    end
  end

  describe '#run with default (no subcommand)' do
    let(:argv) { [] }

    it 'lists plugins by default' do
      expect { command.run }.to output(/No plugins loaded/).to_stdout
    end
  end

  describe '#run with --help' do
    let(:argv) { ['--help'] }

    it 'shows usage' do
      expect { command.run }.to output(/el plugin/).to_stdout
    end
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
# rubocop:enable Lint/EmptyBlock
