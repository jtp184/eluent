# frozen_string_literal: true

module Eluent
  module Storage
    # Manages all path resolution for a repository.
    # Single responsibility: knows where things live on disk.
    #
    # Handles both normal git repositories (where .git is a directory) and
    # git worktrees (where .git is a file pointing to the main repository).
    class Paths
      ELUENT_DIR = '.eluent'
      DATA_FILE = 'data.jsonl' # Primary storage: atoms, bonds, comments (synced via git)
      EPHEMERAL_FILE = 'ephemeral.jsonl' # Local-only data: scratchpad, drafts (gitignored)
      CONFIG_FILE = 'config.yaml' # Repository configuration: defaults, custom statuses

      # Pattern to extract gitdir path from worktree .git file
      GITDIR_PATTERN = /\Agitdir:\s*(.+)\s*\z/

      attr_reader :root

      def initialize(root_path)
        @root = File.expand_path(root_path)
      end

      def eluent_dir = File.join(root, ELUENT_DIR)
      def data_file = File.join(eluent_dir, DATA_FILE)
      def ephemeral_file = File.join(eluent_dir, EPHEMERAL_FILE)
      def config_file = File.join(eluent_dir, CONFIG_FILE)
      def formulas_dir = File.join(eluent_dir, 'formulas')
      def plugins_dir = File.join(eluent_dir, 'plugins')
      def gitignore_file = File.join(eluent_dir, '.gitignore')
      def sync_state_file = File.join(eluent_dir, '.sync-state')
      def git_dir = File.join(root, '.git')

      # Returns the path to the git config file.
      #
      # For normal repositories, this is .git/config.
      # For worktrees, this resolves to the main repository's .git/config
      # by following the gitdir pointer in the worktree's .git file.
      def git_config_file
        @git_config_file ||= File.join(git_common_dir, 'config')
      end

      # Returns the "common" git directory shared across all worktrees.
      #
      # For normal repositories: returns .git/
      # For worktrees: follows the gitdir pointer to find the main .git/
      #
      # This is equivalent to `git rev-parse --git-common-dir` but without
      # shelling out, for performance.
      def git_common_dir
        @git_common_dir ||= resolve_git_common_dir
      end

      def data_file_exists?
        File.exist?(data_file)
      end

      # Backward-compatible alias
      alias initialized? data_file_exists?

      def ephemeral_exists?
        File.exist?(ephemeral_file)
      end

      # Returns true if this is a git repository (normal or worktree).
      #
      # Detects both:
      # - Normal repos: .git is a directory
      # - Worktrees: .git is a file containing "gitdir: /path/to/main/.git/worktrees/name"
      def git_repo?
        File.exist?(git_dir)
      end

      # Returns true if this is a git worktree (not the main repository).
      def git_worktree?
        File.file?(git_dir) && !worktree_gitdir.nil?
      end

      private

      # Resolves the common git directory for both normal repos and worktrees.
      #
      # For worktrees, the .git file contains something like:
      #   gitdir: /path/to/main/.git/worktrees/worktree-name
      #
      # The common dir is the main .git (two levels up from worktrees/name).
      def resolve_git_common_dir
        return git_dir if Dir.exist?(git_dir)
        return git_dir unless File.file?(git_dir)

        gitdir = worktree_gitdir
        return git_dir unless gitdir

        # gitdir points to .git/worktrees/<name>, common dir is .git/
        # Go up two levels: worktrees/<name> -> worktrees -> .git
        common = File.expand_path('../..', gitdir)
        Dir.exist?(common) ? common : git_dir
      end

      # Extracts the gitdir path from a worktree's .git file.
      # Returns nil if not a valid worktree pointer.
      def worktree_gitdir
        return nil unless File.file?(git_dir)

        content = File.read(git_dir, 1024) # Limit read size for safety
        match = content.match(GITDIR_PATTERN)
        return nil unless match

        path = match[1]
        # Handle relative paths (resolve relative to the .git file location)
        path.start_with?('/') ? path : File.expand_path(path, root)
      end
    end
  end
end
