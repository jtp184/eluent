# frozen_string_literal: true

module Eluent
  module Models
    # Mixin to provide singleton-like collection behavior to classes, while allowing user extension
    module ExtendableCollection
      def self.included(base)
        class << base
          attr_writer :defaults

          def all
            @all ||= defaults.to_h do |name, options|
              [name, new(name:, **options)]
            end
          end

          def defaults
            @defaults ||= {}
          end

          def [](name)
            all.fetch(name)
          end

          def []=(name, instance)
            all[name] = instance
          end
        end
      end
    end
  end
end
