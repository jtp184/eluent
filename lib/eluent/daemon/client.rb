# frozen_string_literal: true

require 'socket'
require 'timeout'

module Eluent
  module Daemon
    # Client for connecting to daemon via Unix socket
    # Single responsibility: send requests and receive responses
    class Client
      DEFAULT_TIMEOUT = 30
      SYNC_TIMEOUT = 300 # 5 minutes for sync operations

      attr_reader :socket_path

      def initialize(socket_path: nil)
        @socket_path = socket_path || default_socket_path
        @socket = nil
      end

      def connected?
        !socket.nil? && !socket.closed?
      end

      def connect
        raise ConnectionError, "Socket not found: #{socket_path}" unless File.exist?(socket_path)

        @socket = UNIXSocket.new(socket_path)
        self
      rescue Errno::ECONNREFUSED
        raise ConnectionError, 'Connection refused: daemon not running?'
      rescue Errno::ENOENT
        raise ConnectionError, "Socket not found: #{socket_path}"
      end

      def disconnect
        socket&.close
        @socket = nil
        self
      end

      def send_request(cmd:, args: {}, timeout: DEFAULT_TIMEOUT)
        connect unless connected?

        request = Protocol.build_request(cmd: cmd, args: args)
        socket.write(Protocol.encode(request))

        Timeout.timeout(timeout) do
          Protocol.decode(socket)
        end
      rescue Timeout::Error
        raise TimeoutError, "Request timed out after #{timeout}s"
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        disconnect
        raise ConnectionError, 'Connection lost'
      end

      # Convenience methods for common commands

      def ping
        send_request(cmd: 'ping')
      end

      def list(repo_path:, **filters)
        send_request(cmd: 'list', args: { repo_path: repo_path, **filters })
      end

      def show(repo_path:, id:)
        send_request(cmd: 'show', args: { repo_path: repo_path, id: id })
      end

      def create(repo_path:, **attrs)
        send_request(cmd: 'create', args: { repo_path: repo_path, **attrs })
      end

      def update(repo_path:, id:, **attrs)
        send_request(cmd: 'update', args: { repo_path: repo_path, id: id, **attrs })
      end

      def close(repo_path:, id:, reason: nil)
        send_request(cmd: 'close', args: { repo_path: repo_path, id: id, reason: reason })
      end

      def sync(repo_path:, **options)
        send_request(cmd: 'sync', args: { repo_path: repo_path, **options }, timeout: SYNC_TIMEOUT)
      end

      private

      attr_reader :socket

      def default_socket_path
        File.expand_path('~/.eluent/daemon.sock')
      end
    end

    class ConnectionError < Error; end
    class TimeoutError < Error; end
  end
end
