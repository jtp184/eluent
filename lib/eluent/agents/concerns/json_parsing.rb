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
        rescue JSON::ParserError
          {}
        end

        def closed_item?(content)
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
