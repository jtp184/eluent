# frozen_string_literal: true

require_relative 'base'

module Eluent
  module Storage
    module Serializers
      # Serializes Comment objects to/from JSON
      module CommentSerializer
        extend Base

        ATTRIBUTES = %i[id parent_id author content created_at updated_at].freeze

        class << self
          def deserialize(data)
            return nil unless type_match?(data)

            build_from_hash(data)
          end

          alias comment? type_match?

          private

          def extract_attributes(data) = data.slice(*ATTRIBUTES)
          def model_class = Models::Comment
          def type_name = 'comment'
        end
      end
    end
  end
end
