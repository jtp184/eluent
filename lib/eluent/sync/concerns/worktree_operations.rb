# frozen_string_literal: true

module Eluent
  module Sync
    module Concerns
      # Worktree operations for GitAdapter.
      #
      # Manages git worktrees - separate working directories that share
      # the same repository. Used by LedgerSyncer to maintain a dedicated
      # worktree for the ledger branch without disturbing the main checkout.
      #
      # @see WorktreeInfo for worktree list result structure
      module WorktreeOperations
        def worktree_list
          output = run_git('worktree', 'list', '--porcelain')
          parse_worktree_list(output)
        rescue GitError => e
          raise WorktreeError.new("Failed to list worktrees: #{e.message}",
                                  command: e.command, stderr: e.stderr, exit_code: e.exit_code)
        end

        # Adds a worktree at the specified path for the given branch.
        # Idempotent: returns existing worktree if path is already a valid worktree.
        #
        # Note: There's a theoretical TOCTOU race between checking if the path
        # exists and running `git worktree add`. If something else creates
        # the path in between, git will fail and we'll raise WorktreeError.
        # This is acceptable since callers should retry or handle the error.
        def worktree_add(path:, branch:)
          BranchError.validate_branch_name!(branch)
          expanded_path = File.expand_path(path)

          if File.exist?(expanded_path)
            existing = worktree_list.find { |wt| wt.path == expanded_path }
            return existing if existing

            raise WorktreeError, "Path '#{expanded_path}' exists but is not a valid worktree"
          end

          run_git('worktree', 'add', expanded_path, branch)
          worktree_list.find { |wt| wt.path == expanded_path }
        rescue BranchError
          raise
        rescue GitError => e
          raise WorktreeError.new("Failed to add worktree at '#{path}': #{e.message}",
                                  command: e.command, stderr: e.stderr, exit_code: e.exit_code)
        end

        def worktree_remove(path:, force: false)
          expanded_path = File.expand_path(path)

          unless worktree_list.any? { |wt| wt.path == expanded_path }
            return true # Idempotent: path doesn't exist as worktree
          end

          args = %w[worktree remove]
          args << '--force' if force
          args << expanded_path
          run_git(*args)
          true
        rescue GitError => e
          raise WorktreeError.new("Failed to remove worktree at '#{path}': #{e.message}",
                                  command: e.command, stderr: e.stderr, exit_code: e.exit_code)
        end

        def worktree_prune
          run_git('worktree', 'prune')
        rescue GitError => e
          raise WorktreeError.new("Failed to prune worktrees: #{e.message}",
                                  command: e.command, stderr: e.stderr, exit_code: e.exit_code)
        end

        # Execute a git command in a specific worktree directory.
        #
        # Validates that the path is actually a registered worktree before
        # running the command. This prevents accidentally running git commands
        # in arbitrary directories.
        #
        # @param worktree_path [String] Path to the worktree
        # @param args [Array<String>] Git command arguments (without 'git')
        # @return [String] Command stdout
        # @raise [WorktreeError] if path is not a valid worktree
        # @raise [GitError] if the git command fails
        #
        # @example
        #   adapter.run_git_in_worktree('/path/to/worktree', 'status', '--porcelain')
        def run_git_in_worktree(worktree_path, *args)
          expanded_path = File.expand_path(worktree_path)

          unless worktree_list.any? { |wt| wt.path == expanded_path }
            raise WorktreeError, "Path '#{expanded_path}' is not a valid worktree"
          end

          command = ['git', '-C', expanded_path, *args]
          stdout, stderr, status = Open3.capture3(*command)

          unless status.success?
            raise GitError.new(
              stderr.strip.empty? ? 'Git command failed' : stderr.strip,
              command: command.join(' '),
              stderr: stderr,
              exit_code: status.exitstatus
            )
          end

          stdout
        end

        private

        def parse_worktree_list(output)
          worktrees = []
          current = {}

          output.each_line do |line|
            line = line.chomp
            case line
            when /\Aworktree (.+)\z/
              current[:path] = Regexp.last_match(1)
            when /\AHEAD ([a-f0-9]+)\z/
              current[:commit] = Regexp.last_match(1)
            when %r{\Abranch refs/heads/(.+)\z}
              current[:branch] = Regexp.last_match(1)
            when 'bare'
              current[:branch] = '(bare)'
            when 'detached'
              current[:branch] = '(detached HEAD)'
            when ''
              worktrees << WorktreeInfo.new(**current) if current[:path]
              current = {}
            end
          end

          worktrees << WorktreeInfo.new(**current) if current[:path]
          worktrees
        end
      end
    end
  end
end
