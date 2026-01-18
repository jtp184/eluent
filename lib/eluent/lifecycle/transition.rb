# frozen_string_literal: true

module Eluent
  module Lifecycle
    # Error raised when an invalid status transition is attempted
    class InvalidTransitionError < Eluent::Error
      attr_reader :from_status, :to_status, :allowed

      def initialize(from_status:, to_status:, allowed:)
        @from_status = from_status
        @to_status = to_status
        @allowed = allowed
        super("Cannot transition from '#{from_status}' to '#{to_status}'. Allowed: #{allowed.join(', ')}")
      end
    end

    # Status state machine with allowed transitions
    class Transition
      TRANSITIONS = {
        open: { to: %i[in_progress blocked deferred closed discard] },
        in_progress: { to: %i[open blocked deferred closed discard] },
        blocked: { to: %i[open in_progress deferred closed discard] },
        deferred: { to: %i[open in_progress blocked closed discard] },
        closed: { to: %i[open discard] },
        discard: { to: %i[open closed] }
      }.freeze

      class << self
        # Check if a transition is valid
        def valid?(from:, to:)
          from_sym = normalize_status(from)
          to_sym = normalize_status(to)

          return false unless TRANSITIONS.key?(from_sym)

          TRANSITIONS[from_sym][:to].include?(to_sym)
        end

        # Validate transition and raise if invalid
        def validate!(from:, to:)
          from_sym = normalize_status(from)
          to_sym = normalize_status(to)
          allowed = allowed_transitions(from: from_sym)

          return true if allowed.include?(to_sym)

          raise InvalidTransitionError.new(
            from_status: from_sym,
            to_status: to_sym,
            allowed: allowed
          )
        end

        # Get list of allowed transitions from a given status
        def allowed_transitions(from:)
          from_sym = normalize_status(from)
          TRANSITIONS.dig(from_sym, :to) || []
        end

        private

        def normalize_status(status)
          case status
          when Models::Status then status.name
          when Symbol then status
          when String then status.to_sym
          else
            raise ArgumentError, "Invalid status type: #{status.class}"
          end
        end
      end
    end
  end
end
