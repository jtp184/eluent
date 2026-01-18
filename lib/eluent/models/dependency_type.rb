# frozen_string_literal: true

module Eluent
  module Models
    # Bond inter-dependency type entity
    class DependencyType
      include ExtendableCollection

      self.defaults = {
        blocks: { blocking: true },
        parent_child: { blocking: true },
        conditional_blocks: { blocking: true },
        waits_for: { blocking: true },
        related: { blocking: false },
        duplicates: { blocking: false },
        discovered_from: { blocking: false },
        replies_to: { blocking: false }
      }.freeze

      attr_reader :name, :blocking

      def initialize(name:, blocking: false)
        @name = name
        @blocking = blocking
      end

      def blocking?
        !!@blocking
      end

      def ==(other)
        other.is_a?(DependencyType) && other.name == name
      end

      def eql?(other)
        self == other
      end

      def hash
        name.hash
      end

      def to_s
        name.to_s
      end

      def to_sym
        name
      end
    end
  end
end
