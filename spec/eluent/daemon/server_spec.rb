# frozen_string_literal: true

RSpec.describe Eluent::Daemon::Server do
  let(:socket_path) { '/tmp/test-daemon.sock' }
  let(:pid_path) { '/tmp/test-daemon.pid' }
  let(:server) { described_class.new(socket_path: socket_path, pid_path: pid_path) }

  describe '#initialize' do
    it 'sets socket path' do
      expect(server.socket_path).to eq(socket_path)
    end

    it 'sets pid path' do
      expect(server.pid_path).to eq(pid_path)
    end

    it 'uses default paths when not provided' do
      default_server = described_class.new
      expect(default_server.socket_path).to eq(described_class::SOCKET_PATH)
      expect(default_server.pid_path).to eq(described_class::PID_PATH)
    end
  end

  describe '#running?' do
    context 'when pid file does not exist' do
      it 'returns false' do
        expect(server).not_to be_running
      end
    end

    context 'when pid file exists but process is dead', :filesystem do
      before do
        FakeFS.activate!
        FakeFS::FileSystem.clear
        FileUtils.mkdir_p(File.dirname(pid_path))
        File.write(pid_path, '99999999') # Non-existent PID
      end

      after { FakeFS.deactivate! }

      it 'returns false' do
        # The process check will fail for non-existent PID
        expect(server).not_to be_running
      end
    end
  end

  describe '#status' do
    context 'when not running' do
      it 'returns status hash with running: false' do
        status = server.status
        expect(status[:running]).to be false
        expect(status[:pid]).to be_nil
        expect(status[:socket]).to be_nil
      end
    end
  end

  describe '#start' do
    context 'when already running' do
      before do
        allow(server).to receive(:running?).and_return(true)
        allow(server).to receive(:read_pid).and_return(12345)
      end

      it 'raises AlreadyRunningError' do
        expect { server.start }.to raise_error(Eluent::Daemon::AlreadyRunningError, /already running/)
      end
    end
  end

  describe '#stop' do
    context 'when not running' do
      it 'raises NotRunningError' do
        expect { server.stop }.to raise_error(Eluent::Daemon::NotRunningError)
      end
    end
  end

  describe 'constants' do
    it 'has reasonable max message size' do
      expect(Eluent::Daemon::Protocol::MAX_MESSAGE_SIZE).to eq(10 * 1024 * 1024)
    end

    it 'has state persist interval' do
      expect(described_class::STATE_PERSIST_INTERVAL).to eq(5)
    end
  end
end
