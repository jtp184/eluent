# frozen_string_literal: true

require 'fileutils'

module Eluent
  module Storage
    class GlobalPathsError < Error; end

    # Resolves paths under ~/.eluent/<repo>/ for ledger sync infrastructure.
    #
    # These paths are user-scoped (stored in the home directory) so they can be shared
    # across multiple local clones of the same repository. This enables a single git
    # worktree for the ledger branch to serve all working copies.
    #
    # Directory structure:
    #   ~/.eluent/                        (or $XDG_DATA_HOME/eluent/)
    #   └── <repo_name>/                  repository namespace
    #       ├── .sync-worktree/           ledger branch checkout
    #       ├── .ledger-sync-state        sync metadata (JSON)
    #       └── .ledger.lock              cross-process lock file
    #
    # @example
    #   paths = GlobalPaths.new(repo_name: 'my-project')
    #   paths.ensure_directories!
    #   paths.sync_worktree_dir  # => "/home/user/.eluent/my-project/.sync-worktree"
    #
    class GlobalPaths
      # Default directory name when XDG_DATA_HOME is not set.
      # Uses a dotfile in home directory for discoverability.
      DEFAULT_DIR_NAME = '.eluent'

      # XDG Base Directory Specification uses 'eluent' (no dot) under the data home.
      # See: https://specifications.freedesktop.org/basedir-spec/latest/
      XDG_DIR_NAME = 'eluent'

      SYNC_WORKTREE_DIR_NAME = '.sync-worktree'
      LEDGER_SYNC_STATE_FILE_NAME = '.ledger-sync-state'
      LEDGER_LOCK_FILE_NAME = '.ledger.lock'

      # Characters invalid in filesystem paths across platforms (Windows + POSIX).
      INVALID_PATH_CHARS = %r{[/\\:*?"<>|]}

      # Maximum length for sanitized repo name (conservative cross-platform limit).
      # ext4 allows 255 bytes; NTFS allows 255 UTF-16 code units; HFS+ allows 255 UTF-16.
      # We use 200 to leave room for file names within the repo directory.
      MAX_REPO_NAME_LENGTH = 200

      attr_reader :repo_name, :original_repo_name

      def initialize(repo_name:)
        @original_repo_name = repo_name
        @repo_name = sanitize_repo_name(repo_name)
        validate_repo_name!
      end

      # Root directory for all eluent data.
      # Respects XDG_DATA_HOME if set, otherwise uses ~/.eluent/
      def global_dir = @global_dir ||= xdg_data_home? ? xdg_eluent_dir : default_eluent_dir

      # Directory for this specific repository's sync data.
      def repo_dir = @repo_dir ||= File.join(global_dir, repo_name)

      # Git worktree checkout of the ledger branch.
      def sync_worktree_dir = @sync_worktree_dir ||= File.join(repo_dir, SYNC_WORKTREE_DIR_NAME)

      # JSON file tracking sync timestamps and offline claims.
      def ledger_sync_state_file = @ledger_sync_state_file ||= File.join(repo_dir, LEDGER_SYNC_STATE_FILE_NAME)

      # Lock file for cross-process synchronization during ledger operations.
      def ledger_lock_file = @ledger_lock_file ||= File.join(repo_dir, LEDGER_LOCK_FILE_NAME)

      # Creates global_dir and repo_dir if they don't exist.
      # @raise [GlobalPathsError] if directory creation fails
      def ensure_directories!
        create_directory(global_dir)
        create_directory(repo_dir)
      rescue SystemCallError => e
        raise GlobalPathsError, "Cannot create directories: #{e.message}"
      end

      # Returns true if both directories exist and are writable.
      # Call ensure_directories! first if you need to create them.
      def writable? = directory_writable?(global_dir) && directory_writable?(repo_dir)

      # Returns true if the repo_name was modified to remove invalid characters.
      def name_was_sanitized? = original_repo_name != repo_name

      private

      def xdg_data_home? = ENV.key?('XDG_DATA_HOME') && !ENV['XDG_DATA_HOME'].empty?

      def xdg_eluent_dir = File.join(ENV.fetch('XDG_DATA_HOME'), XDG_DIR_NAME)

      def default_eluent_dir
        File.join(Dir.home, DEFAULT_DIR_NAME)
      rescue ArgumentError
        raise GlobalPathsError, 'HOME environment variable is not set'
      end

      def sanitize_repo_name(name)
        return '' if name.nil?

        sanitized = name.to_s
                        .strip
                        .gsub(/\A\.+/, '')             # Remove leading dots FIRST (handles .., ..., .hidden)
                        .gsub(/\.+\z/, '')             # Remove trailing dots (Windows issues)
                        .gsub(INVALID_PATH_CHARS, '_') # Replace invalid chars (including any remaining path separators)
                        .gsub(/\.{2,}/, '_')           # Collapse remaining multi-dot sequences
                        .slice(0, MAX_REPO_NAME_LENGTH)

        warn "el: repo name sanitized from '#{name}' to '#{sanitized}'" if sanitized != name
        sanitized
      end

      def validate_repo_name!
        return unless repo_name.nil? || repo_name.empty?

        raise GlobalPathsError, 'repo_name is required and cannot be empty or whitespace-only'
      end

      def create_directory(path)
        FileUtils.mkdir_p(path)
      end

      def directory_writable?(path) = Dir.exist?(path) && File.writable?(path)
    end
  end
end
