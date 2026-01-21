# frozen_string_literal: true

require 'securerandom'

module Eluent
  module Agents
    module Implementations
      # Executes Claude Code CLI in tmux sessions to work on Eluent atoms.
      # Unlike API-based executors, this spawns an external process and monitors
      # atom status via repository polling until a terminal state is reached.
      class ClaudeCodeExecutor < AgentExecutor
        include Concerns::TmuxSessionManager

        POLL_INTERVAL = 3
        TERMINAL_STATUSES = %i[closed deferred wont_do discard].freeze
        SESSION_NAME_SANITIZER = /[^a-zA-Z0-9]/

        def execute(atom, system_prompt: nil)
          @start_time = monotonic_now
          @session_name = nil
          validate_configuration!

          @session_name = generate_session_name(atom)
          start_session(@session_name, atom, system_prompt)
          monitor_until_complete(@session_name, atom)

          build_success_result(atom)
        rescue ConfigurationError, SessionError, TimeoutError => e
          destroy_session(@session_name) if e.is_a?(TimeoutError) && @session_name
          ExecutionResult.failure(error: e.message, atom: atom)
        ensure
          cleanup_session(@session_name) if @session_name && !configuration.preserve_sessions
        end

        private

        def monitor_until_complete(session_name, atom)
          loop do
            check_execution_timeout!

            refreshed = repository.find_atom(atom.id)
            raise session_error("Atom #{atom.id} deleted during execution", session_name, :monitor) unless refreshed
            return if terminal_status?(refreshed)

            unless session_exists?(session_name)
              raise session_error('Session terminated without closing atom', session_name, :monitor)
            end

            sleep POLL_INTERVAL
          end
        end

        def terminal_status?(atom)
          TERMINAL_STATUSES.include?(atom.status.to_sym)
        end

        def check_execution_timeout!
          elapsed = monotonic_now - @start_time
          return unless elapsed > configuration.execution_timeout

          raise TimeoutError.new(
            "Execution timeout (#{configuration.execution_timeout}s) exceeded",
            timeout_seconds: elapsed
          )
        end

        def validate_configuration!
          raise ConfigurationError.new('tmux not installed or not in PATH', field: :tmux) unless tmux_available?

          return if claude_code_available?

          raise ConfigurationError.new('Claude Code CLI not found',
                                       field: :claude_code_path)
        end

        def tmux_available?
          system('command -v tmux > /dev/null 2>&1')
        end

        def claude_code_available?
          path = configuration.claude_code_path
          path.include?('/') ? File.executable?(path) : system("command -v #{path} > /dev/null 2>&1")
        end

        def generate_session_name(atom)
          safe_id = atom.id.to_s.gsub(SESSION_NAME_SANITIZER, '-')[0..7]
          "eluent-#{safe_id}-#{Time.now.to_i}-#{SecureRandom.hex(4)}"
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def session_error(message, session_name, operation)
          SessionError.new(message, session_name: session_name, operation: operation)
        end
      end
    end
  end
end
