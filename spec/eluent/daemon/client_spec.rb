# frozen_string_literal: true

RSpec.describe Eluent::Daemon::Client do
  let(:socket_path) { '/tmp/test-daemon.sock' }
  let(:client) { described_class.new(socket_path: socket_path) }

  describe '#initialize' do
    it 'sets socket path' do
      expect(client.socket_path).to eq(socket_path)
    end

    it 'uses default socket path when not provided' do
      default_client = described_class.new
      expect(default_client.socket_path).to eq(File.expand_path('~/.eluent/daemon.sock'))
    end
  end

  describe '#connected?' do
    it 'returns false initially' do
      expect(client).not_to be_connected
    end
  end

  describe '#connect' do
    context 'when socket does not exist' do
      it 'raises ConnectionError' do
        expect { client.connect }.to raise_error(
          Eluent::Daemon::ConnectionError,
          /Socket not found/
        )
      end
    end
  end

  describe '#disconnect' do
    it 'returns self' do
      expect(client.disconnect).to eq(client)
    end
  end

  describe 'convenience methods' do
    # These methods are wrappers around send_request, tested via integration
    describe '#ping' do
      it 'responds to ping' do
        expect(client).to respond_to(:ping)
      end
    end

    describe '#list' do
      it 'responds to list' do
        expect(client).to respond_to(:list)
      end
    end

    describe '#show' do
      it 'responds to show' do
        expect(client).to respond_to(:show)
      end
    end

    describe '#create' do
      it 'responds to create' do
        expect(client).to respond_to(:create)
      end
    end

    describe '#update' do
      it 'responds to update' do
        expect(client).to respond_to(:update)
      end
    end

    describe '#close' do
      it 'responds to close' do
        expect(client).to respond_to(:close)
      end
    end

    describe '#sync' do
      it 'responds to sync' do
        expect(client).to respond_to(:sync)
      end
    end
  end
end
