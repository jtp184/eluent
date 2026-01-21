# frozen_string_literal: true

module Eluent
  module Sync
    module Concerns
      # Worktree lifecycle management for LedgerSyncer.
      #
      # Git worktrees allow multiple working directories to share a single repository.
      # This module manages a dedicated worktree for the ledger sync branch, providing:
      #
      # - Creation: Setting up the worktree directory linked to the sync branch
      # - Validation: Detecting corrupted or misconfigured worktrees
      # - Recovery: Rebuilding worktrees that have become stale
      #
      # A worktree becomes "stale" when its directory exists but git no longer
      # recognizes it as valid (e.g., after disk errors or interrupted operations).
      #
      # @note Requires including class to provide:
      #   - #git_adapter - GitAdapter instance
      #   - #global_paths - GlobalPaths instance with #sync_worktree_dir
      #   - #branch - the branch name for the worktree
      module LedgerWorktree
        # Detects if the worktree directory exists but is in an invalid state.
        #
        # A worktree is considered stale when ANY of these conditions apply:
        # 1. The .git file is missing or corrupted
        # 2. Git cannot verify it as a valid worktree
        # 3. It's checked out to a different branch than expected
        #
        # @return [Boolean] true if worktree needs recovery, false if healthy or absent
        def worktree_stale?
          return false unless worktree_dir_exists?

          !worktree_git_valid? || !worktree_branch_matches?
        end

        # Removes and recreates a stale worktree to restore it to a valid state.
        #
        # This is a destructive operation that discards any uncommitted changes
        # in the worktree. Safe to call when worktree is not stale (no-op).
        def recover_stale_worktree!
          return unless worktree_stale?

          git_adapter.worktree_remove(path: worktree_path, force: true)
          git_adapter.worktree_prune
          ensure_worktree!
        end

        private

        # Creates the worktree if it doesn't exist in git's worktree registry.
        #
        # @return [Boolean] true if worktree was created, false if already existed
        def ensure_worktree!
          return false if worktree_registered?

          git_adapter.worktree_add(path: worktree_path, branch: branch)
          true
        end

        # Checks if git's worktree registry includes this worktree path.
        # Note: This is distinct from worktree_dir_exists? which checks the filesystem.
        def worktree_registered?
          git_adapter.worktree_list.any? { |wt| wt.path == worktree_path }
        end

        # Checks if the worktree directory exists on the filesystem.
        def worktree_dir_exists?
          Dir.exist?(worktree_path)
        end

        # Validates that git recognizes this directory as a functional worktree.
        def worktree_git_valid?
          git_file = File.join(worktree_path, '.git')
          return false unless File.exist?(git_file)

          git_adapter.run_git_in_worktree(worktree_path, 'rev-parse', '--git-dir')
          true
        rescue GitError
          false
        end

        # Verifies the worktree is checked out to the expected branch.
        # Returns false if worktree info cannot be found or branch doesn't match.
        def worktree_branch_matches?
          info = git_adapter.worktree_list.find { |wt| wt.path == worktree_path }
          return false unless info

          info.branch == branch
        end

        def remove_worktree_if_exists
          return unless worktree_registered?

          git_adapter.worktree_remove(path: worktree_path, force: true)
        end

        def worktree_path
          @worktree_path ||= global_paths.sync_worktree_dir
        end
      end
    end
  end
end
