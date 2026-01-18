# frozen_string_literal: true

require 'yaml'

module Eluent
  module Storage
    # Loads and validates repository configuration
    # Single responsibility: config file management
    class ConfigLoader
      REPO_NAME_PATTERN = /\A[a-z][a-z0-9_-]{0,31}\z/

      DEFAULT_CONFIG = {
        'repo_name' => nil,
        'defaults' => {
          'priority' => 2,
          'issue_type' => 'task'
        },
        'ephemeral' => {
          'cleanup_days' => 7
        },
        'compaction' => {
          'tier1_days' => 30,
          'tier2_days' => 90
        }
      }.freeze

      def initialize(paths:, repo_name_inferrer: nil)
        @paths = paths
        @repo_name_inferrer = repo_name_inferrer || RepoNameInferrer.new(paths)
      end

      def load
        return default_with_inferred_name unless File.exist?(paths.config_file)

        raw_config = YAML.safe_load_file(paths.config_file) || {}
        validate(raw_config)
      end

      def write_initial(repo_name:)
        config = DEFAULT_CONFIG.dup
        config['repo_name'] = repo_name
        File.write(paths.config_file, YAML.dump(config))
        config
      end

      private

      attr_reader :paths, :repo_name_inferrer

      def default_with_inferred_name
        DEFAULT_CONFIG.dup.tap do |config|
          config['repo_name'] = repo_name_inferrer.infer
        end
      end

      def validate(raw_config)
        DEFAULT_CONFIG.dup.tap do |result|
          result['repo_name'] = validate_repo_name(raw_config['repo_name'])
          result['defaults'] = merge_defaults(raw_config['defaults'])
          result['ephemeral'] = validate_ephemeral(raw_config['ephemeral'], result['ephemeral'])
          result['compaction'] = validate_compaction(raw_config['compaction'], result['compaction'])
        end
      end

      def validate_repo_name(name)
        name && REPO_NAME_PATTERN.match?(name) ? name : repo_name_inferrer.infer
      end

      def merge_defaults(raw_defaults)
        return DEFAULT_CONFIG['defaults'].dup unless raw_defaults.is_a?(Hash)

        DEFAULT_CONFIG['defaults'].merge(raw_defaults)
      end

      def validate_ephemeral(raw_ephemeral, defaults)
        return defaults unless raw_ephemeral&.dig('cleanup_days')

        days = raw_ephemeral['cleanup_days'].to_i
        if days.between?(1, 365)
          defaults.merge('cleanup_days' => days)
        else
          warn 'el: warning: ephemeral.cleanup_days must be 1-365, using default (7)'
          defaults
        end
      end

      def validate_compaction(raw_compaction, defaults)
        return defaults unless raw_compaction.is_a?(Hash)

        result = defaults.dup

        if (tier1 = raw_compaction['tier1_days']&.to_i) && tier1 >= 1 && tier1 <= 365
          result['tier1_days'] = tier1
        end

        if (tier2 = raw_compaction['tier2_days']&.to_i) && tier2 > result['tier1_days'] && tier2 <= 730
          result['tier2_days'] = tier2
        end

        result
      end
    end

    # Infers repository name from git config or directory name
    class RepoNameInferrer
      REPO_NAME_PATTERN = ConfigLoader::REPO_NAME_PATTERN

      GIT_URL_PATTERN = %r{
        url \s* = \s*    # key = value
        .*/ ([^/]+?)     # capture repo name after last /
        (?:\.git)?       # optional .git suffix
        \s* $            # end of line
      }x

      INVALID_NAME_CHARS = /[^a-z0-9_-]/

      def initialize(paths)
        @paths = paths
      end

      def infer
        from_git_remote || from_directory_name
      end

      private

      attr_reader :paths

      def from_git_remote
        return unless paths.git_repo? && File.exist?(paths.git_config_file)

        content = File.read(paths.git_config_file)
        match = content.match(GIT_URL_PATTERN)
        return unless match

        normalize_name(match[1])
      end

      def from_directory_name
        normalize_name(File.basename(paths.root))
      end

      def normalize_name(name)
        normalized = name.downcase.gsub(INVALID_NAME_CHARS, '-')
        REPO_NAME_PATTERN.match?(normalized) ? normalized : nil
      end
    end
  end
end
