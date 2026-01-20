# frozen_string_literal: true

module Eluent
  # Plugin system for extending Eluent functionality
  # Provides hooks, custom commands, and type extensions
  module Plugins
    # Coordinates plugin discovery, loading, and hook invocation
    # Central entry point for the plugin system
    class PluginManager
      # Relative path for plugins directory (used for both local and global)
      PLUGINS_DIR = '.eluent/plugins'

      attr_reader :hooks, :registry, :gem_loader

      def initialize
        @hooks = HooksManager.new
        @registry = PluginRegistry.new
        @gem_loader = GemLoader.new
        @loaded = false
      end

      # Load all plugins from all sources
      # @param local_path [String, nil] Path to local plugins directory
      # @param load_gems [Boolean] Whether to load gem plugins
      def load_all!(local_path: nil, load_gems: true)
        return if loaded?

        load_local_plugins(local_path) if local_path
        load_global_plugins
        load_gem_plugins if load_gems

        @loaded = true
      end

      # Check if plugins have been loaded
      def loaded?
        @loaded
      end

      # Register a plugin
      # This is the main entry point called by plugins
      # Uses transaction pattern: register first, rollback on block failure
      # @param name [String] Plugin name
      # @param path [String, nil] File path the plugin was loaded from
      def register(name, path: nil, &block)
        info = registry.register(name, path: path)
        context = PluginDefinitionContext.new(name: name, hooks_manager: hooks, registry: registry)
        context.instance_eval(&block) if block
        info
      rescue StandardError
        # Rollback: cleanup registry and any partial hook registrations on failure
        registry.unregister(name)
        hooks.unregister(name)
        raise
      end

      # Invoke a hook
      # @param name [Symbol] Hook name
      # @param context [HookContext] Context to pass to callbacks
      # @return [HookResult] Result of invocation
      def invoke_hook(name, context)
        hooks.invoke(name, context)
      end

      # Create a hook context
      # @param item [Models::Atom, nil] The item being operated on
      # @param repo [Storage::JsonlRepository] The repository
      # @param event [Symbol] The event type
      # @param changes [Hash] Changes being applied
      # @param metadata [Hash] Additional context
      def create_context(item:, repo:, event:, changes: {}, metadata: {})
        HookContext.new(
          item: item,
          repo: repo,
          event: event,
          changes: changes,
          metadata: metadata
        )
      end

      # Find a custom command by name
      # @param name [String] Command name
      # @return [Hash, nil] Command info or nil
      def find_command(name)
        registry.find_command(name)
      end

      # Get all custom commands
      def all_commands
        registry.all_commands
      end

      # Get all loaded plugins
      def all_plugins
        registry.all
      end

      # Unload all plugins (for testing)
      def reset!
        hooks.clear!
        registry.clear!
        @loaded = false
      end

      private

      def load_local_plugins(base_path)
        dir = File.join(base_path, PLUGINS_DIR)
        load_plugins_from_dir(dir, source: :local)
      end

      def load_global_plugins
        global_dir = File.join(Dir.home, PLUGINS_DIR)
        load_plugins_from_dir(global_dir, source: :global)
      rescue ArgumentError
        # Dir.home can raise ArgumentError if HOME is not set
        nil
      end

      def load_gem_plugins
        gem_loader.load_all!
      end

      def load_plugins_from_dir(dir, source:)
        return unless Dir.exist?(dir)

        Dir.glob(File.join(dir, '*.rb')).each do |path|
          load_plugin_file(path, source: source)
        end
      end

      def load_plugin_file(path, source:)
        # Detect circular dependencies
        loading_stack = Thread.current[:eluent_loading_plugins] ||= Set.new
        if loading_stack.include?(path)
          raise PluginLoadError.new(
            "Circular dependency detected while loading plugin: #{path}",
            path: path
          )
        end

        loading_stack.add(path)

        # Store the path so register can use it
        Thread.current[:eluent_loading_plugin_path] = path
        Thread.current[:eluent_loading_plugin_source] = source

        load path
      rescue PluginLoadError
        raise
      rescue StandardError => e
        raise PluginLoadError.new(
          "Failed to load plugin from #{path}: #{e.message}",
          path: path
        )
      ensure
        Thread.current[:eluent_loading_plugin_path] = nil
        Thread.current[:eluent_loading_plugin_source] = nil
        Thread.current[:eluent_loading_plugins]&.delete(path)
      end
    end

    # Module-level singleton and DSL
    class << self
      # Get or create the global plugin manager (thread-safe)
      def manager
        @manager_mutex ||= Mutex.new
        @manager_mutex.synchronize { @manager ||= PluginManager.new }
      end

      # Register a plugin using the module-level DSL
      # Example:
      #   Eluent::Plugins.register "my-plugin" do
      #     before_create { |ctx| ... }
      #   end
      def register(name, &)
        path = Thread.current[:eluent_loading_plugin_path]
        manager.register(name, path: path, &)
      end

      # Reset the global manager (for testing)
      def reset!
        @manager_mutex ||= Mutex.new
        @manager_mutex.synchronize do
          @manager&.reset!
          @manager = nil
        end
      end
    end
  end
end
