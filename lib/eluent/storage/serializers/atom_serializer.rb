# frozen_string_literal: true

require_relative 'base'

module Eluent
  module Storage
    module Serializers
      # Serializes Atom objects to/from JSON
      module AtomSerializer
        extend Base

        ATTRIBUTES = %i[
          id title description status issue_type priority labels
          assignee parent_id defer_until close_reason created_at updated_at metadata
        ].freeze

        class << self
          def deserialize(data)
            return nil unless type_match?(data)

            build_from_hash(data)
          end

          alias atom? type_match?

          private

          def extract_attributes(data) = data.slice(*ATTRIBUTES)
          def model_class = Models::Atom
          def type_name = 'atom'
        end
      end
    end
  end
end
