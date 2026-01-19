# frozen_string_literal: true

require 'socket'
require 'fileutils'

module Eluent
  module Daemon
    # Unix socket server for daemon mode
    # Single responsibility: manage socket lifecycle and connections
    class Server
      SOCKET_PATH = File.expand_path('~/.eluent/daemon.sock')
      PID_PATH = File.expand_path('~/.eluent/daemon.pid')
      LOG_PATH = File.expand_path('~/.eluent/daemon.log')
      STATE_PERSIST_INTERVAL = 5 # seconds

      attr_reader :socket_path, :pid_path

      def initialize(socket_path: SOCKET_PATH, pid_path: PID_PATH, config: {})
        @socket_path = socket_path
        @pid_path = pid_path
        @config = config
        @server_socket = nil
        @running = false
        @clients = []
        @mutex = Mutex.new
        @router = CommandRouter.new
      end

      def start(foreground: false)
        raise AlreadyRunningError, "Daemon already running (PID: #{read_pid})" if running?

        cleanup_stale_socket

        foreground ? run_foreground : daemonize
      end

      def stop
        pid = read_pid
        raise NotRunningError, 'Daemon not running' unless pid

        Process.kill('TERM', pid)
        wait_for_shutdown(pid)
        true
      rescue Errno::ESRCH
        # Process already dead, clean up
        cleanup_files
        true
      end

      def running?
        pid = read_pid
        return false unless pid

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def status
        pid = read_pid

        if pid && running?
          { running: true, pid: pid, socket: socket_path }
        else
          { running: false, pid: nil, socket: nil }
        end
      end

      private

      attr_reader :config, :server_socket, :clients, :mutex, :router

      def run_foreground
        ensure_eluent_dir
        write_pid_file
        setup_signal_handlers
        setup_socket
        accept_connections
      ensure
        graceful_shutdown
      end

      def daemonize
        ensure_eluent_dir

        # Fork once
        if fork
          # Parent waits briefly to check startup
          sleep 0.5
          if File.exist?(pid_path)
            puts "Daemon started (PID: #{File.read(pid_path).strip})"
          else
            warn 'Failed to start daemon'
            exit 1
          end
          return
        end

        # Child: become session leader
        Process.setsid

        # Fork again to prevent terminal acquisition
        exit if fork

        # Redirect standard streams
        $stdin.reopen(File::NULL)
        $stdout.reopen(LOG_PATH, 'a')
        $stderr.reopen($stdout)
        $stdout.sync = true

        Dir.chdir('/')

        write_pid_file
        setup_signal_handlers
        setup_socket
        accept_connections
      rescue StandardError => e
        File.open(LOG_PATH, 'a') { |f| f.puts "#{Time.now.utc.iso8601} ERROR: #{e.message}\n#{e.backtrace.join("\n")}" }
        raise
      ensure
        graceful_shutdown
      end

      def ensure_eluent_dir
        FileUtils.mkdir_p(File.dirname(socket_path))
      end

      def write_pid_file
        File.write(pid_path, Process.pid.to_s)
      end

      def read_pid
        return nil unless File.exist?(pid_path)

        pid = File.read(pid_path).strip.to_i
        pid.positive? ? pid : nil
      end

      def setup_socket
        FileUtils.rm_f(socket_path)
        @server_socket = UNIXServer.new(socket_path)
        File.chmod(0o600, socket_path)
        @running = true
        log "Server started on #{socket_path}"
      end

      def cleanup_stale_socket
        return unless File.exist?(socket_path)

        pid = read_pid
        return if pid && process_alive?(pid)

        # Stale socket - clean up
        log 'Cleaning up stale socket'
        FileUtils.rm_f(socket_path)
        FileUtils.rm_f(pid_path)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def setup_signal_handlers
        Signal.trap('TERM') { @running = false }
        Signal.trap('INT') { @running = false }
      end

      def accept_connections
        while @running
          begin
            # Use wait_readable with timeout to allow checking @running
            next unless server_socket.wait_readable(1)

            client = server_socket.accept
            Thread.new(client) { |c| handle_connection(c) }
          rescue IOError, Errno::EBADF
            # Socket closed during shutdown
            break
          rescue StandardError => e
            log "Accept error: #{e.message}"
          end
        end
      end

      def handle_connection(socket)
        mutex.synchronize { clients << socket }

        loop do
          request = Protocol.decode(socket)
          break if request.nil? # Client disconnected

          log "Request: #{request[:cmd]} (#{request[:id]})"
          response = router.route(request)
          socket.write(Protocol.encode(response))
        end
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        # Client disconnected
      rescue ProtocolError => e
        log "Protocol error: #{e.message}"
        begin
          error_response = Protocol.build_error(id: nil, code: 'PROTOCOL_ERROR', message: e.message)
          socket.write(Protocol.encode(error_response))
        rescue StandardError
          # Ignore errors sending error response
        end
      rescue StandardError => e
        log "Connection error: #{e.message}"
      ensure
        mutex.synchronize { clients.delete(socket) }
        begin
          socket.close
        rescue StandardError
          nil
        end
      end

      def graceful_shutdown
        log 'Shutting down...'
        @running = false

        # Close server socket
        begin
          server_socket&.close
        rescue StandardError
          nil
        end

        # Wait for clients with timeout
        deadline = Time.now + 5
        sleep 0.1 until clients.empty? || Time.now > deadline

        # Force close remaining clients
        mutex.synchronize do
          clients.each { |c| c.close rescue nil }
          clients.clear
        end

        cleanup_files
        log 'Shutdown complete'
      end

      def cleanup_files
        FileUtils.rm_f(socket_path)
        FileUtils.rm_f(pid_path)
      end

      def wait_for_shutdown(pid, timeout: 10)
        deadline = Time.now + timeout

        while Time.now < deadline
          return true unless process_alive?(pid)

          sleep 0.1
        end

        # Force kill if still running
        begin
          Process.kill('KILL', pid)
        rescue StandardError
          nil
        end
        cleanup_files
        true
      end

      def log(message)
        timestamp = Time.now.utc.iso8601
        line = "#{timestamp} #{message}"

        if $stdout.tty?
          puts line
        else
          # In daemon mode, write to log file
          begin
            File.open(LOG_PATH, 'a') { |f| f.puts line }
          rescue StandardError
            nil
          end
        end
      end
    end

    class AlreadyRunningError < Error; end
    class NotRunningError < Error; end
  end
end
