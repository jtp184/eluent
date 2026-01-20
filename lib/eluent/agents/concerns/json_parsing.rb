# frozen_string_literal: true

require 'json'

module Eluent
  module Agents
    module Concerns
      # Shared JSON parsing utilities for agent executors
      module JsonParsing
        private

        def parse_json(str)
          JSON.parse(str)
        rescue JSON::ParserError => e
          warn "[Eluent] Failed to parse JSON: #{e.message}" if ENV['ELUENT_DEBUG']
          {}
        end

        # Checks if a tool result JSON indicates work completion.
        # The AI signals completion by using close_item, which returns JSON with a 'closed' key.
        # This is part of the contract between the executor and AI: when the AI calls close_item,
        # it signals that work on the current atom is complete.
        # @param content [String] JSON string from a tool result
        # @return [Boolean] true if the tool result indicates the item was closed
        def tool_result_closes_item?(content)
          return false unless content

          parsed = parse_json(content)
          parsed.is_a?(Hash) && parsed.key?('closed')
        rescue JSON::ParserError
          false
        end
      end
    end
  end
end
