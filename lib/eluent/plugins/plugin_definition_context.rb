# frozen_string_literal: true

module Eluent
  module Plugins
    # DSL context for plugin definition (registration-time).
    # Provides the API available inside `Eluent::Plugins.register "name" do ... end`
    #
    # This context is used at plugin load time to register hooks, commands, and type extensions.
    # It is distinct from HookContext, which is passed to callbacks at runtime when hooks fire.
    # The naming reflects this temporal difference:
    #   - PluginDefinitionContext: used once when plugin is defined/loaded
    #   - HookContext: used each time a hook callback is invoked
    class PluginDefinitionContext
      attr_reader :name

      def initialize(name:, hooks_manager:, registry:)
        @name = name
        @hooks_manager = hooks_manager
        @registry = registry
      end

      # Dynamically generates hook registration methods for all lifecycle hooks.
      # This creates methods like #before_create, #after_create, #on_status_change, etc.
      # Each generated method accepts a `priority:` keyword argument and a block.
      #
      # Example usage in a plugin:
      #   before_create(priority: 50) { |ctx| validate_something(ctx) }
      #   after_close { |ctx| notify_something(ctx) }
      HooksManager::LIFECYCLE_HOOKS.each do |hook_name|
        define_method(hook_name) do |priority: 100, &block|
          register_hook(hook_name, priority: priority, &block)
        end
      end

      # Register a custom command
      # @param name [String] Command name (must not conflict with built-in commands)
      # @param description [String] Command description for help
      def command(name, description: nil, &block)
        raise InvalidPluginError.new('Command handler required', plugin_name: self.name) unless block

        registry.register_command(name, plugin_name: self.name, description: description, &block)
      end

      # Register a custom issue type
      # @param name [Symbol] Type name
      # @param abstract [Boolean] If true, type cannot be directly instantiated
      def register_issue_type(name, abstract: false)
        Models::IssueType[name] = Models::IssueType.new(name: name.to_sym, abstract: abstract)
        registry.record_extension(self.name, :issue_types, name)
      end

      # Register a custom status type
      # @param name [Symbol] Status name
      # @param from [Array<Symbol>] Valid transition sources
      # @param to [Array<Symbol>] Valid transition targets
      def register_status_type(name, from: [], to: [])
        Models::Status[name] = Models::Status.new(name: name.to_sym, from: from.map(&:to_sym), to: to.map(&:to_sym))
        registry.record_extension(self.name, :status_types, name)
      end

      # Register a custom dependency type
      # @param name [Symbol] Dependency type name
      # @param blocking [Boolean] If true, creates blocking relationship
      def register_dependency_type(name, blocking: true)
        Models::DependencyType[name] = Models::DependencyType.new(name: name.to_sym, blocking: blocking)
        registry.record_extension(self.name, :dependency_types, name)
      end

      private

      attr_reader :hooks_manager, :registry

      def register_hook(hook_name, priority:, &block)
        raise InvalidPluginError.new('Hook handler required', plugin_name: name) unless block

        hooks_manager.register(hook_name, plugin_name: name, priority: priority, &block)
        registry.track_hook(name, hook_name)
      end
    end
  end
end
