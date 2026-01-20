# frozen_string_literal: true

module Eluent
  module Agents
    # Base error for all agent-related errors
    class AgentError < Error; end

    # Raised when agent configuration is invalid
    class ConfigurationError < AgentError
      attr_reader :field

      def initialize(message, field: nil)
        super(message)
        @field = field
      end
    end

    # Raised when agent execution fails
    class ExecutionError < AgentError
      attr_reader :atom_id, :phase

      def initialize(message, atom_id: nil, phase: nil)
        super(message)
        @atom_id = atom_id
        @phase = phase
      end
    end

    # Raised when an API request fails
    class ApiError < AgentError
      attr_reader :status_code, :response_body

      def initialize(message, status_code: nil, response_body: nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
      end
    end

    # Raised when rate limited by API
    class RateLimitError < ApiError
      attr_reader :retry_after

      def initialize(message = 'Rate limit exceeded', status_code: 429, retry_after: nil, **)
        super(message, status_code: status_code, **)
        @retry_after = retry_after
      end
    end

    # Raised when authentication fails
    class AuthenticationError < ApiError
      def initialize(message = 'Authentication failed', status_code: 401, **)
        super
      end
    end

    # Raised when API request times out
    class TimeoutError < AgentError
      attr_reader :timeout_seconds

      def initialize(message = 'Request timed out', timeout_seconds: nil)
        super(message)
        @timeout_seconds = timeout_seconds
      end
    end

    # Raised when claiming an atom fails
    class ClaimError < AgentError
      attr_reader :atom_id, :reason

      def initialize(message, atom_id: nil, reason: nil)
        super(message)
        @atom_id = atom_id
        @reason = reason
      end
    end
  end
end
