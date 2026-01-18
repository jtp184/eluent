# frozen_string_literal: true

require 'json'

module Eluent
  module Storage
    module Serializers
      # Shared serialization behavior for model objects
      # Models must implement #to_h returning a hash with :_type key
      module Base
        def serialize(model)
          JSON.generate(model.to_h)
        end

        def type_match?(data)
          symbolize_keys(data)[:_type] == type_name
        end

        private

        def symbolize_keys(hash)
          return hash unless hash.is_a?(Hash)

          hash.transform_keys(&:to_sym)
        end

        def build_from_hash(data)
          model_class.new(**extract_attributes(symbolize_keys(data)))
        end

        def extract_attributes(data)
          raise NotImplementedError, "#{self.class} must implement #extract_attributes"
        end

        def model_class
          raise NotImplementedError, "#{self.class} must implement #model_class"
        end

        def type_name
          raise NotImplementedError, "#{self.class} must implement #type_name"
        end
      end
    end
  end
end
