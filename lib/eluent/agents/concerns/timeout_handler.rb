# frozen_string_literal: true

module Eluent
  module Agents
    module Concerns
      # Shared timeout checking logic for agent executors
      module TimeoutHandler
        private

        def check_timeouts!(tool_call_count, start_time)
          check_tool_call_limit!(tool_call_count)
          check_execution_timeout!(start_time)
        end

        def check_tool_call_limit!(tool_call_count)
          return unless tool_call_count >= configuration.max_tool_calls

          raise ExecutionError.new(
            "Max tool calls (#{configuration.max_tool_calls}) exceeded",
            phase: :tool_limit
          )
        end

        def check_execution_timeout!(start_time)
          elapsed = Time.now - start_time
          return unless elapsed > configuration.execution_timeout

          raise TimeoutError.new(
            "Execution timeout (#{configuration.execution_timeout}s) exceeded",
            timeout_seconds: elapsed
          )
        end
      end
    end
  end
end
