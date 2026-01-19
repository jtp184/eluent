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
      DEFAULT_READ_TIMEOUT = 30 # seconds

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
      def decode(io, timeout: DEFAULT_READ_TIMEOUT)
        # Read length prefix - nil means clean EOF (client disconnected)
        length_bytes = read_exact(io, LENGTH_PREFIX_SIZE, timeout: timeout, error_message: 'Incomplete length prefix')
        return nil if length_bytes.nil?

        length = length_bytes.unpack1(LENGTH_PREFIX_FORMAT)

        if length > MAX_MESSAGE_SIZE
          raise MessageTooLargeError,
                "Message size #{length} exceeds maximum #{MAX_MESSAGE_SIZE}"
        end

        # Read message body - nil here means truncated message (protocol error)
        json = read_exact(io, length, timeout: timeout, error_message: 'Incomplete message body')
        raise ProtocolError, 'Incomplete message body' if json.nil?

        JSON.parse(json, symbolize_names: true)
      rescue JSON::ParserError => e
        raise ProtocolError, "Invalid JSON: #{e.message}"
      end

      # Read exactly n bytes from IO, handling partial reads with timeout
      # Returns nil for empty stream, raises ProtocolError for partial reads or timeout
      def read_exact(io, bytes_needed, timeout: DEFAULT_READ_TIMEOUT, error_message: 'Incomplete read')
        # Use blocking read for StringIO and other non-selectable streams (e.g., in tests)
        return read_exact_blocking(io, bytes_needed, error_message) unless selectable?(io)

        read_exact_with_timeout(io, bytes_needed, timeout, error_message)
      end

      def selectable?(io)
        return false unless io.respond_to?(:to_io)

        real_io = io.to_io
        real_io.is_a?(IO) && !real_io.closed?
      rescue IOError, TypeError
        false
      end

      def read_exact_blocking(io, bytes_needed, error_message)
        buffer = String.new(encoding: Encoding::BINARY)

        while buffer.bytesize < bytes_needed
          remaining = bytes_needed - buffer.bytesize
          chunk = io.read(remaining)

          if chunk.nil? || chunk.empty?
            return nil if buffer.empty?

            raise ProtocolError, error_message
          end

          buffer << chunk
        end

        buffer
      end

      def read_exact_with_timeout(io, bytes_needed, timeout, error_message)
        buffer = String.new(encoding: Encoding::BINARY)
        deadline = Time.now + timeout

        while buffer.bytesize < bytes_needed
          remaining_time = deadline - Time.now
          raise ReadTimeoutError, "Read timeout after #{timeout}s" if remaining_time <= 0

          # Wait for data with timeout
          raise ReadTimeoutError, "Read timeout after #{timeout}s" unless io.wait_readable(remaining_time)

          remaining = bytes_needed - buffer.bytesize
          chunk = io.read_nonblock(remaining, exception: false)

          case chunk
          when :wait_readable
            # IO.select said readable but read_nonblock says wait - retry
            next
          when nil, ''
            # EOF reached
            # If we haven't read anything, return nil (clean EOF)
            return nil if buffer.empty?

            # If we have partial data, raise error (truncated message)
            raise ProtocolError, error_message
          else
            buffer << chunk
          end
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
        { id: id, status: 'ok' }.tap { |r| r[:data] = data if data }
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

      def generate_id = "req-#{SecureRandom.hex(4)}"
    end

    class ProtocolError < Error; end
    class MessageTooLargeError < ProtocolError; end
    class ReadTimeoutError < ProtocolError; end
  end
end
