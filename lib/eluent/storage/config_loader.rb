# frozen_string_literal: true

require 'yaml'
require_relative '../sync/errors'

module Eluent
  module Storage
    # Configuration validation error.
    # Raised when config values are invalid and cannot be corrected.
    class ConfigError < Error; end

    # Loads and validates repository configuration
    # Single responsibility: config file management
    class ConfigLoader
      REPO_NAME_PATTERN = /\A[a-z][a-z0-9_-]{0,31}\z/

      # Valid values for sync.offline_mode option
      OFFLINE_MODES = %w[local fail].freeze

      # Pattern for validating numeric strings (integers or decimals, optionally negative).
      # Strips surrounding whitespace before matching.
      NUMERIC_PATTERN = /\A\s*-?\d+(?:\.\d+)?\s*\z/

      # Limits for sync.claim_retries
      # Min: At least one attempt required for any operation
      # Max: Prevents indefinite retry loops on persistent conflicts
      CLAIM_RETRIES_RANGE = (1..100)

      # Limits for sync.network_timeout (seconds)
      # Min: Below 5s risks timeout on slow connections before git can respond
      # Max: 5 minutes is generous; longer suggests network issues needing user attention
      NETWORK_TIMEOUT_RANGE = (5..300)

      # Maximum claim timeout: 30 days is generous for any workflow
      MAX_CLAIM_TIMEOUT_HOURS = 720

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
        },
        'sync' => {
          'ledger_branch' => nil,         # Branch name for ledger sync (nil = disabled)
          'auto_claim_push' => true,      # Push to remote immediately after claiming
          'claim_retries' => 5,           # Max retry attempts on push conflict
          'claim_timeout_hours' => nil,   # Hours before stale claims auto-release (nil = never)
          'offline_mode' => 'local',      # 'local' = claim locally, sync later; 'fail' = reject if offline
          'network_timeout' => 30,        # Seconds to wait for git network operations
          'global_path_override' => nil   # Override ~/.eluent/ location (e.g., for CI)
        }
      }.freeze

      # @param paths [Paths] Repository paths instance
      # @param repo_name_inferrer [RepoNameInferrer, nil] Optional inferrer for repo names
      def initialize(paths:, repo_name_inferrer: nil)
        @paths = paths
        @repo_name_inferrer = repo_name_inferrer || RepoNameInferrer.new(paths)
      end

      # Loads configuration from the config file, falling back to defaults.
      # @return [Hash] Validated configuration with all defaults merged
      def load
        return default_with_inferred_name unless File.exist?(paths.config_file)

        raw_config = YAML.safe_load_file(paths.config_file) || {}
        validate(raw_config)
      end

      # Creates an initial config file with defaults.
      # @param repo_name [String] Repository name to use
      # @return [Hash] The written configuration
      def write_initial(repo_name:)
        config = dup_defaults
        config['repo_name'] = repo_name
        File.write(paths.config_file, YAML.dump(config))
        config
      end

      private

      attr_reader :paths, :repo_name_inferrer

      # Duplicates DEFAULT_CONFIG with independent copies of nested hashes.
      # This prevents mutations to one config from affecting others.
      def dup_defaults
        DEFAULT_CONFIG.transform_values { |v| v.is_a?(Hash) ? v.dup : v }
      end

      def default_with_inferred_name
        dup_defaults.tap do |config|
          config['repo_name'] = repo_name_inferrer.infer
        end
      end

      def validate(raw_config)
        dup_defaults.tap do |result|
          result['repo_name'] = validate_repo_name(raw_config['repo_name'])
          result['defaults'] = merge_defaults(raw_config['defaults'])
          result['ephemeral'] = validate_ephemeral(raw_config['ephemeral'], result['ephemeral'])
          result['compaction'] = validate_compaction(raw_config['compaction'], result['compaction'])
          result['sync'] = validate_sync(raw_config['sync'], result['sync'])
        end
      end

      def validate_repo_name(name)
        return repo_name_inferrer.infer unless name && REPO_NAME_PATTERN.match?(name)

        name
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

      # Validates all sync configuration options.
      #
      # Validation philosophy:
      # - Options with discrete valid values (ledger_branch, offline_mode) raise
      #   ConfigError if invalid, requiring the user to fix their config.
      # - Numeric options (claim_retries, network_timeout) clamp to valid ranges
      #   with warnings, allowing the system to continue with safe defaults.
      def validate_sync(raw_sync, defaults)
        return defaults unless raw_sync.is_a?(Hash)

        defaults.dup.tap do |result|
          result['ledger_branch'] = validate_ledger_branch(raw_sync['ledger_branch'])
          result['auto_claim_push'] = coerce_boolean(raw_sync['auto_claim_push'], defaults['auto_claim_push'])
          result['claim_retries'] = clamp_claim_retries(raw_sync['claim_retries'], defaults['claim_retries'])
          result['claim_timeout_hours'] = validate_claim_timeout_hours(raw_sync['claim_timeout_hours'])
          result['offline_mode'] = validate_offline_mode(raw_sync['offline_mode'], defaults['offline_mode'])
          result['network_timeout'] = clamp_network_timeout(raw_sync['network_timeout'], defaults['network_timeout'])
          result['global_path_override'] = expand_path_override(raw_sync['global_path_override'])
        end
      end

      def validate_ledger_branch(value)
        return nil if value.nil?

        branch = value.to_s.strip
        return nil if branch.empty?

        unless Sync::BranchError.valid_branch_name?(branch)
          raise ConfigError, "Invalid sync.ledger_branch: '#{branch}' is not a valid git branch name"
        end

        branch
      end

      # Coerces a value to boolean, handling YAML's string parsing quirks.
      # YAML may parse booleans as strings depending on quoting.
      #
      # Returns default for: nil, ""
      # Returns false for: false, "false", "no", "0"
      # Returns true for: true, "true", "yes", any other non-empty string
      def coerce_boolean(value, default)
        return default if value.nil?
        return value if [true, false].include?(value)

        str = value.to_s.strip.downcase
        return default if str.empty?
        return false if %w[false no 0].include?(str)

        true
      end

      # Clamps claim_retries to valid range, warning if adjustment needed.
      def clamp_claim_retries(value, default)
        clamp_to_range(
          value:, default:, range: CLAIM_RETRIES_RANGE, option: 'sync.claim_retries',
          min_message: "must be at least #{CLAIM_RETRIES_RANGE.min}, using #{CLAIM_RETRIES_RANGE.min}",
          max_message: "capped at #{CLAIM_RETRIES_RANGE.max} to prevent excessive delays"
        )
      end

      # Validates claim_timeout_hours. Returns nil for disabled, or the hours value.
      # Zero and negative values are treated as "disabled" (nil).
      # Non-numeric values warn and return nil (disabled).
      def validate_claim_timeout_hours(value)
        return nil if value.nil?

        # Handle non-numeric strings that would silently become 0.0 via to_f
        if value.is_a?(String) && !value.match?(NUMERIC_PATTERN)
          warn "el: warning: sync.claim_timeout_hours '#{value.strip}' is not a number, ignoring"
          return nil
        end

        hours = value.to_f
        return nil if hours <= 0

        if hours > MAX_CLAIM_TIMEOUT_HOURS
          warn "el: warning: sync.claim_timeout_hours capped at #{MAX_CLAIM_TIMEOUT_HOURS} hours (30 days)"
          return MAX_CLAIM_TIMEOUT_HOURS.to_f
        end

        warn 'el: warning: sync.claim_timeout_hours < 1 may cause premature claim releases' if hours < 1

        hours
      end

      def validate_offline_mode(value, default)
        return default if value.nil?

        mode = value.to_s.strip.downcase
        return mode if OFFLINE_MODES.include?(mode)

        raise ConfigError, "Invalid sync.offline_mode: '#{value}'. Valid options: #{OFFLINE_MODES.join(', ')}"
      end

      # Clamps network_timeout to valid range, warning if adjustment needed.
      def clamp_network_timeout(value, default)
        clamp_to_range(
          value:, default:, range: NETWORK_TIMEOUT_RANGE, option: 'sync.network_timeout',
          min_message: "must be at least #{NETWORK_TIMEOUT_RANGE.min}s, using #{NETWORK_TIMEOUT_RANGE.min}",
          max_message: "capped at #{NETWORK_TIMEOUT_RANGE.max}s"
        )
      end

      # Generic clamping with warnings for values outside valid range.
      def clamp_to_range(value:, default:, range:, option:, min_message:, max_message:)
        return default if value.nil?

        int_value = value.to_i
        return int_value if range.cover?(int_value)

        if int_value < range.min
          warn "el: warning: #{option} #{min_message}"
          range.min
        else
          warn "el: warning: #{option} #{max_message}"
          range.max
        end
      end

      # Expands global_path_override, resolving ~ and relative paths.
      # Empty strings are treated as "not configured" (nil).
      # Paths starting with - are rejected (could be misinterpreted as flags).
      def expand_path_override(value)
        return nil if value.nil?

        path = value.to_s.strip
        return nil if path.empty?

        raise ConfigError, "Invalid sync.global_path_override: '#{path}' cannot start with '-'" if path.start_with?('-')

        File.expand_path(path)
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
