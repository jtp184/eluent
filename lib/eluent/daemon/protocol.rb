# frozen_string_literal: true

require 'json'
require 'securerandom'

module Eluent
  module Daemon
    # Length-prefixed JSON protocol for IPC
    # Single responsibility: encode/decode messages
    module Protocol
      LENGTH_PREFIX_FORMAT = 'N' # 4-byte big-endian uint32
      LENGTH_PREFIX_SIZE = 4
      MAX_MESSAGE_SIZE = 10 * 1024 * 1024 # 10MB

      module_function

      # Encode a message with length prefix
      def encode(message)
        json = message.is_a?(String) ? message : JSON.generate(message)
        length = json.bytesize

        if length > MAX_MESSAGE_SIZE
          raise MessageTooLargeError,
                "Message size #{length} exceeds maximum #{MAX_MESSAGE_SIZE}"
        end

        [length].pack(LENGTH_PREFIX_FORMAT) + json
      end

      # Read and parse a message from IO
      def decode(io)
        # Read length prefix
        length_bytes = io.read(LENGTH_PREFIX_SIZE)
        return nil if length_bytes.nil? || length_bytes.empty?

        raise ProtocolError, 'Incomplete length prefix' if length_bytes.bytesize < LENGTH_PREFIX_SIZE

        length = length_bytes.unpack1(LENGTH_PREFIX_FORMAT)

        if length > MAX_MESSAGE_SIZE
          raise MessageTooLargeError,
                "Message size #{length} exceeds maximum #{MAX_MESSAGE_SIZE}"
        end

        # Read message body
        json = io.read(length)
        raise ProtocolError, 'Incomplete message body' if json.nil? || json.bytesize < length

        JSON.parse(json, symbolize_names: true)
      rescue JSON::ParserError => e
        raise ProtocolError, "Invalid JSON: #{e.message}"
      end

      # Build a request message
      def build_request(cmd:, args: {}, id: nil)
        {
          cmd: cmd.to_s,
          args: args,
          id: id || generate_id
        }
      end

      # Build a success response
      def build_success(id:, data: nil)
        response = {
          id: id,
          status: 'ok'
        }
        response[:data] = data if data
        response
      end

      # Build an error response
      def build_error(id:, code:, message:, details: nil)
        error_data = {
          code: code,
          message: message
        }
        error_data[:details] = details if details

        {
          id: id,
          status: 'error',
          error: error_data
        }
      end

      def generate_id
        "req-#{SecureRandom.hex(4)}"
      end
    end

    class ProtocolError < Error; end
    class MessageTooLargeError < ProtocolError; end
  end
end
