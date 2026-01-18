# frozen_string_literal: true

require_relative 'base'

module Eluent
  module Storage
    module Serializers
      # Serializes Bond objects to/from JSON
      module BondSerializer
        extend Base

        ATTRIBUTES = %i[source_id target_id dependency_type created_at metadata].freeze

        class << self
          def deserialize(data)
            return nil unless type_match?(data)

            build_from_hash(data)
          end

          alias bond? type_match?

          private

          def extract_attributes(data) = data.slice(*ATTRIBUTES)
          def model_class = Models::Bond
          def type_name = 'bond'
        end
      end
    end
  end
end
