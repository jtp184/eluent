# frozen_string_literal: true

require 'httpx'
require 'json'

module Eluent
  module Agents
    module Implementations
      # Agent executor using Claude API (Anthropic)
      class ClaudeExecutor < AgentExecutor
        include Concerns::TimeoutHandler
        include Concerns::HttpErrorHandler
        include Concerns::JsonParsing

        API_URL = 'https://api.anthropic.com/v1/messages'
        MODEL = 'claude-sonnet-4-20250514'
        API_VERSION = '2023-06-01'
        MAX_TOKENS = 4096

        def execute(atom, system_prompt: nil)
          validate_configuration!

          prompt = system_prompt || default_system_prompt(atom)
          messages = []
          tool_call_count = 0
          start_time = Time.now

          loop do
            check_timeouts!(tool_call_count, start_time)

            response = make_request(prompt, messages)
            handle_response_errors!(response)

            content = parse_response(response)
            messages << { role: 'assistant', content: content }

            tool_uses = extract_tool_uses(content)
            break if tool_uses.empty?

            tool_results = execute_tools(tool_uses)
            messages << { role: 'user', content: tool_results }
            tool_call_count += tool_uses.size

            break if item_closed?(tool_results)
          end

          build_success_result(atom)
        rescue ConfigurationError, ApiError, TimeoutError, ExecutionError => e
          ExecutionResult.failure(error: e.message, atom: atom)
        end

        private

        def validate_configuration!
          return if configuration.claude_configured?

          raise ConfigurationError.new('Claude API key not configured',
                                       field: :claude_api_key)
        end

        def make_request(system_prompt, messages)
          body = {
            model: MODEL,
            max_tokens: MAX_TOKENS,
            system: system_prompt,
            messages: messages.empty? ? [{ role: 'user', content: 'Begin working on the task.' }] : messages,
            tools: ToolDefinitions.for_claude
          }

          HTTPX
            .with(timeout: { request_timeout: configuration.request_timeout })
            .with(headers: request_headers)
            .post(API_URL, json: body)
        end

        def request_headers
          {
            'Content-Type' => 'application/json',
            'x-api-key' => configuration.claude_api_key,
            'anthropic-version' => API_VERSION
          }
        end

        def parse_response(response)
          body = parse_json(response.body&.to_s || '{}')
          body['content'] || []
        end

        def extract_tool_uses(content)
          return [] unless content.is_a?(Array)

          content.select { |block| block['type'] == 'tool_use' }
        end

        def execute_tools(tool_uses)
          tool_uses.map do |tool_use|
            result = execute_tool(tool_use['name'], tool_use['input'] || {})

            {
              type: 'tool_result',
              tool_use_id: tool_use['id'],
              content: JSON.generate(result)
            }
          end
        end

        def item_closed?(tool_results)
          tool_results.any? { |r| r[:type] == 'tool_result' && tool_result_closes_item?(r[:content]) }
        end
      end
    end
  end
end
