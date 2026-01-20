# frozen_string_literal: true

module Eluent
  module Plugins
    # Discovers and loads eluent-* gems
    # Gems must provide an `eluent/plugin` file that calls Eluent::Plugins.register
    class GemLoader
      GEM_PREFIX = 'eluent-'
      PLUGIN_ENTRY_FILE = 'eluent/plugin'

      LoadedGem = Data.define(:name, :version, :path)

      def initialize
        @loaded_gems = []
      end

      # Find all eluent-* gems available in the current environment
      # @return [Array<Gem::Specification>] Available plugin gems
      def discover
        Gem::Specification.select { |spec| spec.name.start_with?(GEM_PREFIX) }
      end

      # Load all discovered plugin gems
      # @return [Array<LoadedGem>] Successfully loaded gems
      def load_all!
        discover.filter_map { |spec| load_gem(spec) }
      end

      # Load a specific gem by name
      # @param gem_name [String] Name of the gem to load
      # @return [LoadedGem, nil] Loaded gem info or nil if failed
      def load_gem_by_name(gem_name)
        spec = Gem::Specification.find_by_name(gem_name)
        load_gem(spec)
      rescue Gem::MissingSpecError
        nil
      end

      # Get list of already loaded gems
      # @return [Array<LoadedGem>] Loaded gems
      def loaded
        @loaded_gems.dup
      end

      private

      attr_reader :loaded_gems

      def load_gem(spec)
        return nil if already_loaded?(spec)

        entry_file = find_entry_file(spec)
        return nil unless entry_file

        require entry_file

        loaded_gem = LoadedGem.new(
          name: spec.name,
          version: spec.version.to_s,
          path: entry_file
        )

        @loaded_gems << loaded_gem
        loaded_gem
      rescue LoadError => e
        raise PluginLoadError.new(
          "Failed to load gem #{spec.name}: #{e.message}",
          plugin_name: spec.name,
          path: entry_file
        )
      end

      def already_loaded?(spec)
        loaded_gems.any? { |g| g.name == spec.name }
      end

      def find_entry_file(spec)
        # Check if the gem provides the expected entry point
        spec.require_paths.each do |require_path|
          full_path = File.join(spec.gem_dir, require_path, "#{PLUGIN_ENTRY_FILE}.rb")
          return PLUGIN_ENTRY_FILE if File.exist?(full_path)
        end

        # Fallback: try the gem's main file
        main_file = File.join(spec.gem_dir, 'lib', "#{spec.name.tr('-', '/')}.rb")
        return spec.name.tr('-', '/') if File.exist?(main_file)

        nil
      end
    end
  end
end
