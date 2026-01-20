# frozen_string_literal: true

module Eluent
  module Plugins
    # Manages lifecycle hook registration and invocation for the plugin system.
    # Hooks are callbacks registered by plugins that fire at specific lifecycle points
    # (e.g., before/after create, close, update operations).
    #
    # Distinct from PluginRegistry which tracks plugin metadata - this class
    # manages the actual hook callbacks and their execution.
    class HooksManager
      LIFECYCLE_HOOKS = %i[
        before_create after_create
        before_close after_close
        before_update after_update
        on_status_change on_sync
      ].freeze

      # Single hook registration entry
      HookEntry = Data.define(:plugin_name, :priority, :callback) do
        def <=>(other)
          priority <=> other.priority
        end
      end

      # Result of invoking hooks. Has three distinct states:
      # - Success: All hooks completed normally (success=true, halted=false)
      # - Halted: A plugin intentionally stopped the operation via halt! (success=false, halted=true)
      #           This is not an error - it's a deliberate decision by the plugin (e.g., validation failure)
      # - Failed: A hook raised an unexpected exception (success=false, halted=false)
      #           This indicates a bug in the plugin, not an intentional abort
      HookResult = Data.define(:success, :halted, :reason, :plugin) do
        def self.success
          new(success: true, halted: false, reason: nil, plugin: nil)
        end

        def self.halted(reason:, plugin:)
          new(success: false, halted: true, reason: reason, plugin: plugin)
        end

        def self.failed(reason:, plugin:)
          new(success: false, halted: false, reason: reason, plugin: plugin)
        end
      end

      def initialize
        @hooks = LIFECYCLE_HOOKS.to_h { |name| [name, []] }
      end

      # Register a hook callback
      # @param name [Symbol] Hook name from LIFECYCLE_HOOKS
      # @param plugin_name [String] Name of the registering plugin
      # @param priority [Integer] Execution order (lower = earlier). Defaults to 100.
      #   Priority scale: 0 = first, 100 = default, higher values run later.
      #   Example: priority 50 runs before default, priority 200 runs after.
      # @param callback [Proc] Block to call when hook fires
      def register(name, plugin_name:, priority: 100, &callback)
        validate_hook_name!(name)
        raise InvalidPluginError, 'Callback required' unless callback

        entry = HookEntry.new(
          plugin_name: plugin_name,
          priority: priority,
          callback: callback
        )

        hooks[name] << entry
        hooks[name].sort!
        entry
      end

      # Unregister all hooks for a plugin
      # @param plugin_name [String] Plugin to remove hooks for
      def unregister(plugin_name)
        hooks.each_value do |entries|
          entries.reject! { |entry| entry.plugin_name == plugin_name }
        end
      end

      # Invoke all callbacks for a hook
      # @param name [Symbol] Hook name
      # @param context [HookContext] Context passed to callbacks
      # @return [HookResult] Result of invocation
      def invoke(name, context)
        validate_hook_name!(name)

        # Duplicate array for thread-safe iteration
        entries = hooks[name].dup

        entries.each do |entry|
          entry.callback.call(context)
        rescue HookAbortError => e
          return HookResult.halted(reason: e.reason || e.message, plugin: entry.plugin_name)
        rescue StandardError => e
          return HookResult.failed(reason: e.message, plugin: entry.plugin_name)
        end

        HookResult.success
      end

      # Get registered hooks for a given name
      # @param name [Symbol] Hook name
      # @return [Array<HookEntry>] Registered hook entries
      def entries_for(name)
        validate_hook_name!(name)
        hooks[name].dup
      end

      # Get all registered hooks
      # @return [Hash<Symbol, Array<HookEntry>>] All hooks by name
      def all_entries
        hooks.transform_values(&:dup)
      end

      # Check if any hooks are registered for a name
      def registered?(name)
        validate_hook_name!(name)
        hooks[name].any?
      end

      # Clear all hooks (for testing)
      def clear!
        hooks.each_value(&:clear)
      end

      private

      attr_reader :hooks

      def validate_hook_name!(name)
        return if LIFECYCLE_HOOKS.include?(name)

        raise ArgumentError, "Unknown hook: #{name}. Valid hooks: #{LIFECYCLE_HOOKS.join(', ')}"
      end
    end
  end
end
