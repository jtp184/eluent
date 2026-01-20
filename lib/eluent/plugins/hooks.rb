# frozen_string_literal: true

module Eluent
  module Plugins
    # Hook management for lifecycle events
    # Hooks are callbacks registered by plugins, invoked at specific lifecycle points
    class Hooks
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

      # Result of invoking hooks
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
      # @param priority [Integer] Lower runs first (default 100)
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

        hooks[name].each do |entry|
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
