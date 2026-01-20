# frozen_string_literal: true

module Eluent
  module Plugins
    # Base error for all plugin-related errors
    class PluginError < Error; end

    # Raised when a plugin fails to load
    class PluginLoadError < PluginError
      attr_reader :plugin_name, :path

      def initialize(message, plugin_name: nil, path: nil)
        super(message)
        @plugin_name = plugin_name
        @path = path
      end
    end

    # Raised when a hook aborts an operation
    class HookAbortError < PluginError
      attr_reader :plugin_name, :hook_name, :reason

      def initialize(message, plugin_name: nil, hook_name: nil, reason: nil)
        super(message)
        @plugin_name = plugin_name
        @hook_name = hook_name
        @reason = reason
      end
    end

    # Raised when a plugin definition is invalid
    class InvalidPluginError < PluginError
      attr_reader :plugin_name, :details

      def initialize(message, plugin_name: nil, details: nil)
        super(message)
        @plugin_name = plugin_name
        @details = details
      end
    end
  end
end
