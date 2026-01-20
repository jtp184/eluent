# frozen_string_literal: true

require 'socket'

module Eluent
  module Agents
    # Agent configuration with defaults and validation
    class Configuration
      DEFAULT_REQUEST_TIMEOUT = 120
      DEFAULT_EXECUTION_TIMEOUT = 3600
      DEFAULT_MAX_TOOL_CALLS = 50
      DEFAULT_MAX_RETRIES = 3

      def initialize(
        claude_api_key: nil,
        openai_api_key: nil,
        request_timeout: DEFAULT_REQUEST_TIMEOUT,
        execution_timeout: DEFAULT_EXECUTION_TIMEOUT,
        max_tool_calls: DEFAULT_MAX_TOOL_CALLS,
        max_retries: DEFAULT_MAX_RETRIES,
        agent_id: nil
      )
        @claude_api_key = claude_api_key || ENV.fetch('ANTHROPIC_API_KEY', nil)
        @openai_api_key = openai_api_key || ENV.fetch('OPENAI_API_KEY', nil)
        @request_timeout = request_timeout
        @execution_timeout = execution_timeout
        @max_tool_calls = max_tool_calls
        @max_retries = max_retries
        @agent_id = agent_id || generate_agent_id
      end

      def claude_configured?
        !claude_api_key.nil? && !claude_api_key.empty?
      end

      def openai_configured?
        !openai_api_key.nil? && !openai_api_key.empty?
      end

      def any_provider_configured?
        claude_configured? || openai_configured?
      end

      def validate!
        raise ConfigurationError.new('No API provider configured', field: :api_keys) unless any_provider_configured?

        if request_timeout <= 0
          raise ConfigurationError.new('Request timeout must be positive', field: :request_timeout)
        end

        if execution_timeout <= 0
          raise ConfigurationError.new('Execution timeout must be positive', field: :execution_timeout)
        end

        raise ConfigurationError.new('Max tool calls must be positive', field: :max_tool_calls) if max_tool_calls <= 0

        true
      end

      def to_h
        {
          agent_id: agent_id,
          claude_configured: claude_configured?,
          openai_configured: openai_configured?,
          request_timeout: request_timeout,
          execution_timeout: execution_timeout,
          max_tool_calls: max_tool_calls,
          max_retries: max_retries
        }
      end

      attr_reader :claude_api_key, :openai_api_key, :request_timeout,
                  :execution_timeout, :max_tool_calls, :max_retries, :agent_id

      private

      def generate_agent_id
        hostname = Socket.gethostname.split('.').first
        "agent-#{hostname}-#{Process.pid}"
      end
    end
  end
end
