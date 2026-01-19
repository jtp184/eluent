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

      # Read and parse a message from IO.
      #
      # Error handling is intentionally asymmetric:
      # - Length prefix returns nil on clean EOF (client disconnected gracefully)
      # - Message body raises ProtocolError on EOF (client disconnected mid-message)
      #
      # This allows the server to distinguish between:
      # - Normal disconnection (nil return, handled silently)
      # - Protocol violation (exception, may warrant logging)
      def decode(io)
        # Read length prefix - nil means clean EOF (client disconnected)
        length_bytes = read_exact(io, LENGTH_PREFIX_SIZE, error_message: 'Incomplete length prefix')
        return nil if length_bytes.nil?

        length = length_bytes.unpack1(LENGTH_PREFIX_FORMAT)

        if length > MAX_MESSAGE_SIZE
          raise MessageTooLargeError,
                "Message size #{length} exceeds maximum #{MAX_MESSAGE_SIZE}"
        end

        # Read message body - nil here means truncated message (protocol error)
        json = read_exact(io, length, error_message: 'Incomplete message body')
        raise ProtocolError, 'Incomplete message body' if json.nil?

        JSON.parse(json, symbolize_names: true)
      rescue JSON::ParserError => e
        raise ProtocolError, "Invalid JSON: #{e.message}"
      end

      # Read exactly n bytes from IO, handling partial reads
      # Returns nil for empty stream, raises ProtocolError for partial reads
      def read_exact(io, bytes_needed, error_message: 'Incomplete read')
        buffer = String.new(encoding: Encoding::BINARY)

        while buffer.bytesize < bytes_needed
          remaining = bytes_needed - buffer.bytesize
          chunk = io.read(remaining)

          # EOF reached
          if chunk.nil? || chunk.empty?
            # If we haven't read anything, return nil (clean EOF)
            return nil if buffer.empty?

            # If we have partial data, raise error (truncated message)
            raise ProtocolError, error_message
          end

          buffer << chunk
        end

        buffer
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
