# frozen_string_literal: true

module Eluent
  module Sync
    # Represents a git worktree entry from `git worktree list --porcelain`.
    #
    # A worktree is a separate working directory linked to the same repository,
    # allowing multiple branches to be checked out simultaneously. This is used
    # by LedgerSyncer to maintain the ledger branch in a dedicated directory
    # without affecting the user's main working directory.
    #
    # @example Listing worktrees
    #   adapter.worktree_list.each do |wt|
    #     puts "#{wt.branch} at #{wt.path}" unless wt.bare?
    #   end
    #
    # @attr_reader path [String] Absolute path to the worktree directory
    # @attr_reader commit [String, nil] Current HEAD commit SHA (nil for bare repos)
    # @attr_reader branch [String, nil] Branch name, "(bare)", or "(detached HEAD)"
    WorktreeInfo = Data.define(:path, :commit, :branch) do
      def initialize(path:, commit: nil, branch: nil)
        super
      end

      # @return [Boolean] true if this is the bare repository root (no working files)
      def bare? = branch == '(bare)'

      # @return [Boolean] true if HEAD is detached (not on any branch)
      def detached? = branch == '(detached HEAD)'
    end
  end
end
