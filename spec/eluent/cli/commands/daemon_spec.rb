# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/daemon'

RSpec.describe Eluent::CLI::Commands::Daemon do
  let(:server) { instance_double(Eluent::Daemon::Server) }

  before do
    allow(Eluent::Daemon::Server).to receive(:new).and_return(server)
  end

  def run_command(*args, robot_mode: false)
    described_class.new(args, robot_mode: robot_mode).run
  rescue Eluent::Daemon::AlreadyRunningError,
         Eluent::Daemon::NotRunningError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'status action' do
    context 'when daemon is running' do
      before do
        allow(server).to receive(:status).and_return(
          running: true,
          pid: 12_345,
          socket: '/tmp/eluent.sock'
        )
      end

      it 'returns 0' do
        expect(run_command('status', robot_mode: true)).to eq(0)
      end

      it 'outputs running state' do
        output = capture_stdout { run_command('status', robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('ok')
        expect(parsed['data']['running']).to be true
        expect(parsed['data']['pid']).to eq(12_345)
      end
    end

    context 'when daemon is not running' do
      before do
        allow(server).to receive(:status).and_return(
          running: false,
          pid: nil,
          socket: nil
        )
      end

      it 'returns 1' do
        expect(run_command('status', robot_mode: true)).to eq(1)
      end

      it 'outputs not running state' do
        output = capture_stdout { run_command('status', robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('ok')
        expect(parsed['data']['running']).to be false
      end
    end

    it 'is the default action' do
      allow(server).to receive(:status).and_return(running: false, pid: nil, socket: nil)

      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['running']).to be false
    end
  end

  describe 'start action' do
    context 'when daemon starts successfully' do
      before do
        allow(server).to receive(:start)
      end

      it 'returns 0' do
        expect(run_command('start', robot_mode: true)).to eq(0)
      end

      it 'calls start without foreground by default' do
        expect(server).to receive(:start).with(foreground: false)
        run_command('start', robot_mode: true)
      end
    end

    context 'with --foreground flag' do
      before do
        allow(server).to receive(:start)
      end

      it 'calls start with foreground option' do
        expect(server).to receive(:start).with(foreground: true)
        run_command('start', '--foreground', robot_mode: true)
      end
    end

    context 'when daemon is already running' do
      before do
        allow(server).to receive(:start).and_raise(
          Eluent::Daemon::AlreadyRunningError.new('Daemon already running')
        )
      end

      it 'returns error' do
        expect(run_command('start', robot_mode: true)).to eq(1)
      end

      it 'outputs DAEMON_RUNNING error' do
        output = capture_stdout { run_command('start', robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('error')
        expect(parsed['error']['code']).to eq('DAEMON_RUNNING')
      end
    end
  end

  describe 'stop action' do
    context 'when daemon stops successfully' do
      before do
        allow(server).to receive(:stop)
      end

      it 'returns 0' do
        expect(run_command('stop', robot_mode: true)).to eq(0)
      end

      it 'outputs success message' do
        output = capture_stdout { run_command('stop', robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('ok')
      end
    end

    context 'when daemon is not running' do
      before do
        allow(server).to receive(:stop).and_raise(
          Eluent::Daemon::NotRunningError.new('Daemon not running')
        )
      end

      it 'returns error' do
        expect(run_command('stop', robot_mode: true)).to eq(1)
      end

      it 'outputs DAEMON_NOT_RUNNING error' do
        output = capture_stdout { run_command('stop', robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('error')
        expect(parsed['error']['code']).to eq('DAEMON_NOT_RUNNING')
      end
    end
  end

  describe 'invalid action' do
    it 'returns error for unknown action' do
      output = capture_stdout { run_command('unknown', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_ACTION')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el daemon/).to_stdout
    end

    it 'returns 0' do
      expect(run_command('--help')).to eq(0)
    end
  end

  private

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
