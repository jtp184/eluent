# frozen_string_literal: true

require 'httpx'
require 'json'

module Eluent
  module Agents
    module Implementations
      # Agent executor using OpenAI API
      class OpenAIExecutor < AgentExecutor
        include Concerns::TimeoutHandler
        include Concerns::HttpErrorHandler
        include Concerns::JsonParsing

        API_URL = 'https://api.openai.com/v1/chat/completions'
        MODEL = 'gpt-4o'
        MAX_TOKENS = 4096

        def execute(atom, system_prompt: nil)
          validate_configuration!

          prompt = system_prompt || default_system_prompt(atom)
          messages = [
            { role: 'system', content: prompt },
            { role: 'user', content: 'Begin working on the task.' }
          ]
          tool_call_count = 0
          start_time = Time.now

          loop do
            check_timeouts!(tool_call_count, start_time)

            response = make_request(messages)
            handle_response_errors!(response)

            message = parse_response(response)
            messages << message

            tool_calls = message[:tool_calls] || []
            break if tool_calls.empty?

            tool_results = execute_tool_calls(tool_calls)
            messages.concat(tool_results)
            tool_call_count += tool_calls.size

            break if item_closed?(tool_results)
          end

          build_success_result(atom)
        rescue ConfigurationError, ApiError, TimeoutError, ExecutionError => e
          ExecutionResult.failure(error: e.message, atom: atom)
        end

        private

        def validate_configuration!
          return if configuration.openai_configured?

          raise ConfigurationError.new('OpenAI API key not configured',
                                       field: :openai_api_key)
        end

        def make_request(messages)
          body = {
            model: MODEL,
            max_tokens: MAX_TOKENS,
            messages: serialize_messages(messages),
            tools: ToolDefinitions.for_openai
          }

          HTTPX
            .with(timeout: { request_timeout: configuration.request_timeout })
            .with(headers: request_headers)
            .post(API_URL, json: body)
        end

        def request_headers
          {
            'Content-Type' => 'application/json',
            'Authorization' => "Bearer #{configuration.openai_api_key}"
          }
        end

        def serialize_messages(messages)
          messages.map do |msg|
            serialized = { role: msg[:role], content: msg[:content] }
            serialized[:tool_calls] = msg[:tool_calls] if msg[:tool_calls]
            serialized[:tool_call_id] = msg[:tool_call_id] if msg[:tool_call_id]
            serialized
          end
        end

        def parse_response(response)
          body = parse_json(response.body.to_s)
          message = body.dig('choices', 0, 'message') || {}

          result = {
            role: 'assistant',
            content: message['content']
          }

          result[:tool_calls] = parse_tool_calls(message['tool_calls']) if message['tool_calls']

          result
        end

        def parse_tool_calls(tool_calls)
          tool_calls.map do |tc|
            {
              id: tc['id'],
              type: tc['type'],
              function: {
                name: tc.dig('function', 'name'),
                arguments: tc.dig('function', 'arguments')
              }
            }
          end
        end

        def execute_tool_calls(tool_calls)
          tool_calls.map do |tool_call|
            function = tool_call[:function]
            arguments = parse_json(function[:arguments] || '{}')
            result = execute_tool(function[:name], arguments)

            {
              role: 'tool',
              tool_call_id: tool_call[:id],
              content: JSON.generate(result)
            }
          end
        end

        def item_closed?(tool_results)
          tool_results.any? { |r| closed_item?(r[:content]) }
        end

        def build_success_result(atom)
          refreshed_atom = repository.find_atom(atom.id)
          ExecutionResult.success(atom: refreshed_atom, close_reason: refreshed_atom.close_reason)
        end
      end
    end
  end
end
