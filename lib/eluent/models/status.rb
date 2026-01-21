# frozen_string_literal: true

module Eluent
  module Models
    # Error raised when an invalid status transition is attempted
    class InvalidTransitionError < Eluent::Error
      attr_reader :from_status, :to_status, :allowed

      def initialize(from_status:, to_status:, allowed:)
        @from_status = from_status
        @to_status = to_status
        @allowed = allowed
        super("Cannot transition from '#{from_status}' to '#{to_status}'. Allowed: #{allowed&.join(', ') || 'any'}")
      end
    end

    # Work item status entity
    class Status
      include ExtendableCollection

      self.defaults = {
        open: { from: [], to: [] },
        in_progress: { from: [], to: [] },
        blocked: { from: [], to: [] },
        review: { from: [], to: [] },
        testing: { from: [], to: [] },
        deferred: { from: [], to: [] },
        closed: { from: [], to: [] },
        wont_do: { from: [], to: [] },
        discard: { from: [], to: [] }
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

      def can_transition_to?(target)
        return true if to.empty?

        to.include?(normalize(target))
      end

      def can_transition_from?(source)
        return true if from.empty?

        from.include?(normalize(source))
      end

      def allowed_transitions
        to.empty? ? nil : to
      end

      private

      def normalize(status)
        case status
        when Status then status.name
        when Symbol then status
        when String then status.to_sym
        else raise ArgumentError, "Invalid status type: #{status.class}"
        end
      end
    end
  end
end
