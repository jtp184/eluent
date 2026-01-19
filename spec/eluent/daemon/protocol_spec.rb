# frozen_string_literal: true

RSpec.describe Eluent::Daemon::Protocol do
  describe '.encode' do
    it 'adds length prefix to message' do
      message = { cmd: 'ping' }
      encoded = described_class.encode(message)

      # First 4 bytes are the length
      length = encoded[0, 4].unpack1('N')
      json_part = encoded[4..]

      expect(length).to eq(json_part.bytesize)
      expect(JSON.parse(json_part, symbolize_names: true)).to eq(message)
    end

    it 'accepts string messages' do
      json_str = '{"cmd":"ping"}'
      encoded = described_class.encode(json_str)

      length = encoded[0, 4].unpack1('N')
      expect(length).to eq(json_str.bytesize)
    end

    it 'raises error for messages exceeding max size' do
      large_message = { data: 'x' * (described_class::MAX_MESSAGE_SIZE + 1) }
      expect { described_class.encode(large_message) }.to raise_error(Eluent::Daemon::MessageTooLargeError)
    end
  end

  describe '.decode' do
    it 'reads and parses length-prefixed message' do
      message = { cmd: 'ping', id: 'req-123' }
      encoded = described_class.encode(message)
      io = StringIO.new(encoded)

      result = described_class.decode(io)
      expect(result).to eq(message)
    end

    it 'returns nil for empty IO' do
      io = StringIO.new('')
      expect(described_class.decode(io)).to be_nil
    end

    it 'raises error for incomplete length prefix' do
      io = StringIO.new("\x00\x00") # Only 2 bytes
      expect { described_class.decode(io) }.to raise_error(Eluent::Daemon::ProtocolError, /Incomplete length prefix/)
    end

    it 'raises error for message exceeding max size' do
      # Create a length prefix indicating a huge message
      huge_length = [described_class::MAX_MESSAGE_SIZE + 1].pack('N')
      io = StringIO.new(huge_length)
      expect { described_class.decode(io) }.to raise_error(Eluent::Daemon::MessageTooLargeError)
    end

    it 'raises error for invalid JSON' do
      invalid_json = '{invalid}'
      length = [invalid_json.bytesize].pack('N')
      io = StringIO.new(length + invalid_json)

      expect { described_class.decode(io) }.to raise_error(Eluent::Daemon::ProtocolError, /Invalid JSON/)
    end
  end

  describe '.build_request' do
    it 'builds a request with cmd and args' do
      request = described_class.build_request(cmd: 'list', args: { status: 'open' })

      expect(request[:cmd]).to eq('list')
      expect(request[:args]).to eq({ status: 'open' })
      expect(request[:id]).to match(/^req-[a-f0-9]+$/)
    end

    it 'uses provided id' do
      request = described_class.build_request(cmd: 'ping', id: 'custom-id')
      expect(request[:id]).to eq('custom-id')
    end
  end

  describe '.build_success' do
    it 'builds a success response' do
      response = described_class.build_success(id: 'req-123', data: { count: 5 })

      expect(response[:id]).to eq('req-123')
      expect(response[:status]).to eq('ok')
      expect(response[:data]).to eq({ count: 5 })
    end

    it 'omits data when nil' do
      response = described_class.build_success(id: 'req-123')
      expect(response).not_to have_key(:data)
    end
  end

  describe '.build_error' do
    it 'builds an error response' do
      response = described_class.build_error(
        id: 'req-123',
        code: 'NOT_FOUND',
        message: 'Item not found'
      )

      expect(response[:id]).to eq('req-123')
      expect(response[:status]).to eq('error')
      expect(response[:error][:code]).to eq('NOT_FOUND')
      expect(response[:error][:message]).to eq('Item not found')
    end

    it 'includes details when provided' do
      response = described_class.build_error(
        id: 'req-123',
        code: 'AMBIGUOUS',
        message: 'Multiple matches',
        details: { candidates: %w[a b c] }
      )

      expect(response[:error][:details]).to eq({ candidates: %w[a b c] })
    end
  end

  describe '.generate_id' do
    it 'generates unique request IDs' do
      ids = Array.new(10) { described_class.generate_id }
      expect(ids.uniq.size).to eq(10)
    end

    it 'generates IDs with req- prefix' do
      id = described_class.generate_id
      expect(id).to match(/^req-[a-f0-9]{8}$/)
    end
  end
end
