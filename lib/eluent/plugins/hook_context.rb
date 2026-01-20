# frozen_string_literal: true

module Eluent
  module Plugins
    # Context passed to hook callbacks
    # Provides access to the item being operated on and allows aborting operations
    class HookContext
      attr_reader :item, :repo, :changes, :event, :metadata

      # @param item [Models::Atom, Models::Bond, nil] The item being operated on
      # @param repo [Storage::JsonlRepository] The repository
      # @param changes [Hash] Changes being applied (for update hooks)
      # @param event [Symbol] The event type (:create, :close, :update, etc.)
      # @param metadata [Hash] Additional context data
      def initialize(item:, repo:, changes: {}, event: nil, metadata: {})
        @item = item
        @repo = repo
        @changes = changes.freeze
        @event = event
        @metadata = metadata.freeze
        @halted = false
        @halt_reason = nil
      end

      # Abort the operation (only valid for before_* hooks).
      # This method both sets state AND raises an exception:
      # 1. Sets @halted = true and @halt_reason before raising
      # 2. Raises HookAbortError to immediately abort hook processing
      #
      # The state is set first so that if the error is caught and inspected,
      # the context reflects the halted state. HooksManager catches the error
      # and returns a HookResult.halted with the reason.
      #
      # @param reason [String, nil] Reason for aborting (shown to user/logged)
      # @raise [HookAbortError] Always raises to abort the operation
      def halt!(reason = nil)
        @halted = true
        @halt_reason = reason
        raise HookAbortError.new(
          reason || 'Operation halted by plugin',
          reason: reason
        )
      end

      # Check if the operation was halted
      def halted?
        @halted
      end

      # Get the reason for halting, if any
      attr_reader :halt_reason

      # Access item fields safely
      def [](key)
        return nil unless item

        item.respond_to?(key) ? item.public_send(key) : nil
      end

      # Check if this is a before hook event
      def before_hook?
        event.to_s.start_with?('before_')
      end

      # Check if this is an after hook event
      def after_hook?
        event.to_s.start_with?('after_')
      end

      # Get the old value of a changed field
      def old_value(field)
        changes.dig(field, :from)
      end

      # Get the new value of a changed field
      def new_value(field)
        changes.dig(field, :to)
      end
    end
  end
end
