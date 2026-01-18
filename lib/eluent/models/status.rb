# frozen_string_literal: true

module Eluent
  module Models
    # Work item status entity
    class Status
      include ExtendableCollection

      self.defaults = {
        open: { from: [], to: [] },
        in_progress: { from: [], to: [] },
        blocked: { from: [], to: [] },
        deferred: { from: [], to: [] },
        closed: { from: [], to: [] },
        discard: { from: %i[closed], to: [] }
      }.freeze

      attr_reader :name, :from, :to

      def initialize(name:, from: [], to: [])
        @name = name
        @from = from
        @to = to
      end

      def ==(other)
        other.is_a?(Status) && other.name == name
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
