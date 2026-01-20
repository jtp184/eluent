# frozen_string_literal: true

module Eluent
  module Plugins
    # Registry of loaded plugins and their metadata
    # Tracks which plugins are loaded and what they provide
    class PluginRegistry
      # Information about a loaded plugin
      PluginInfo = Data.define(:name, :path, :loaded_at, :hooks, :commands, :extensions) do
        def hook_count
          hooks.values.sum(&:size)
        end

        def command_names
          commands.keys
        end
      end

      def initialize
        @plugins = {}
        @commands = {}
      end

      # Register a plugin
      # @param name [String] Plugin name
      # @param path [String, nil] File path the plugin was loaded from
      # @return [PluginInfo] The registered plugin info
      def register(name, path: nil)
        raise InvalidPluginError.new("Plugin already registered: #{name}", plugin_name: name) if plugins.key?(name)

        info = PluginInfo.new(
          name: name,
          path: path,
          loaded_at: Time.now.utc,
          hooks: Hash.new { |h, k| h[k] = [] },
          commands: {},
          extensions: { issue_types: [], status_types: [], dependency_types: [] }
        )

        plugins[name] = info
        info
      end

      # Unregister a plugin
      # @param name [String] Plugin name
      # @return [Boolean] True if the plugin was unregistered
      def unregister(name)
        return false unless plugins.key?(name)

        info = plugins.delete(name)
        info.command_names.each { |cmd| commands.delete(cmd) }
        true
      end

      # Get plugin info
      # @param name [String] Plugin name
      # @return [PluginInfo, nil] Plugin info or nil if not found
      def [](name)
        plugins[name]
      end

      # Check if a plugin is registered
      def registered?(name)
        plugins.key?(name)
      end

      # List all registered plugins
      # @return [Array<PluginInfo>] All registered plugins
      def all
        plugins.values
      end

      # Get all plugin names
      def names
        plugins.keys
      end

      # Register a command provided by a plugin
      # @param command_name [String] Command name
      # @param plugin_name [String] Plugin providing the command
      # @param handler [Proc] Command handler
      # @param description [String] Command description
      def register_command(command_name, plugin_name:, description: nil, &handler)
        raise InvalidPluginError, "Unknown plugin: #{plugin_name}" unless plugins.key?(plugin_name)

        if commands.key?(command_name)
          raise InvalidPluginError.new(
            "Command already registered: #{command_name}",
            plugin_name: plugin_name
          )
        end

        cmd_info = { handler: handler, description: description, plugin: plugin_name }
        commands[command_name] = cmd_info
        plugins[plugin_name].commands[command_name] = cmd_info
      end

      # Find a command by name
      # @param name [String] Command name
      # @return [Hash, nil] Command info or nil if not found
      def find_command(name)
        commands[name]
      end

      # Get all registered commands
      def all_commands
        commands.dup
      end

      # Record that a plugin registered a hook
      def record_hook(plugin_name, hook_name)
        return unless plugins.key?(plugin_name)

        plugins[plugin_name].hooks[hook_name] << Time.now.utc
      end

      # Record that a plugin registered a type extension
      def record_extension(plugin_name, extension_type, name)
        return unless plugins.key?(plugin_name)

        plugins[plugin_name].extensions[extension_type] << name
      end

      # Clear all plugins (for testing)
      def clear!
        @plugins = {}
        @commands = {}
      end

      private

      attr_reader :plugins, :commands
    end
  end
end
