# frozen_string_literal: true

module Eluent
  module Sync
    module Concerns
      # Provides timeout-aware command execution for GitAdapter.
      #
      # Used for network operations (fetch, push) that may hang on
      # unreliable connections. Includes process cleanup on timeout.
      module TimeoutExecution
        private

        def run_git_with_timeout(*args, timeout:)
          raise ArgumentError, 'Timeout must be positive' unless timeout.is_a?(Numeric) && timeout.positive?

          command = ['git', '-C', repo_path, *args]
          result = execute_with_timeout(command, timeout)
          raise_if_failed(result[:status], result[:stderr], command)
          result[:stdout]
        end

        def execute_with_timeout(command, timeout)
          Open3.popen3(*command) do |_stdin, stdout_io, stderr_io, wait_thread|
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
            threads = spawn_io_readers(stdout_io, stderr_io)

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return wait_for_completion(wait_thread, threads) if finished?(remaining, wait_thread)

            handle_timeout(wait_thread, threads, timeout, command)
          end
        end

        def spawn_io_readers(stdout_io, stderr_io)
          [Thread.new { stdout_io.read }, Thread.new { stderr_io.read }]
        end

        def finished?(remaining, wait_thread)
          remaining.positive? && wait_thread.join(remaining)
        end

        def wait_for_completion(wait_thread, threads)
          { status: wait_thread.value, stdout: threads[0].value, stderr: threads[1].value }
        end

        def handle_timeout(wait_thread, threads, timeout, command)
          kill_process_safely(wait_thread.pid)
          threads.each { |t| t.join(0.1) }
          threads.each(&:kill)
          raise GitTimeoutError.new(
            "Git operation timed out after #{timeout}s",
            timeout: timeout,
            command: command.join(' ')
          )
        end

        def raise_if_failed(status, stderr, command)
          return if status.success?

          raise GitError.new(
            stderr.strip.empty? ? 'Git command failed' : stderr.strip,
            command: command.join(' '),
            stderr: stderr,
            exit_code: status.exitstatus
          )
        end

        def kill_process_safely(pid)
          Process.kill('TERM', pid)
          sleep(0.1)
          Process.kill('KILL', pid) if process_alive?(pid)
        rescue Errno::ESRCH, Errno::EPERM
          # ESRCH: Process already dead
          # EPERM: Process exists but we can't signal it (zombie/owned by other user)
          # Either way, nothing more we can do
        end

        def process_alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          # ESRCH: Process doesn't exist
          # EPERM: Can't signal (treat as dead for our purposes)
          false
        end
      end
    end
  end
end
