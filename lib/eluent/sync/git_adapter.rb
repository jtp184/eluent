# frozen_string_literal: true

require 'open3'
require_relative 'errors'
require_relative 'worktree_info'
require_relative 'concerns/worktree_operations'
require_relative 'concerns/timeout_execution'

module Eluent
  module Sync
    # Safe wrapper for Git CLI operations via shell execution.
    #
    # This adapter exists (rather than using a gem like rugged/git) because:
    # - Direct CLI usage avoids libgit2 compatibility issues across systems
    # - Easier to debug: commands can be run manually to reproduce issues
    # - No native dependencies to compile
    #
    # Design principles:
    # - All methods are thin wrappers around git commands
    # - Errors include the failed command for debugging
    # - Query methods return nil or false on failure (not exceptions)
    # - Mutation methods raise on failure
    # - All paths are expanded to absolute paths
    #
    # @example Basic usage
    #   adapter = GitAdapter.new(repo_path: '/path/to/repo')
    #   adapter.current_branch  # => "main"
    #   adapter.clean?          # => true
    #
    # @see WorktreeInfo for worktree list result structure
    # @see BranchError.validate_branch_name! for branch name validation rules
    class GitAdapter
      include Concerns::WorktreeOperations
      include Concerns::TimeoutExecution

      # Default timeout for network operations (fetch, push).
      # 30 seconds balances responsiveness with tolerance for slow networks.
      DEFAULT_NETWORK_TIMEOUT = 30

      attr_reader :repo_path

      def initialize(repo_path:)
        @repo_path = File.expand_path(repo_path)
      end

      # ------------------------------------------------------------------
      # Query Methods
      # ------------------------------------------------------------------
      # Read-only operations that inspect repository state.
      # These return values directly (strings, booleans) and return
      # nil/false on failure rather than raising exceptions.

      def current_branch
        branch = run_git('rev-parse', '--abbrev-ref', 'HEAD').strip
        raise DetachedHeadError, 'Cannot sync: HEAD is detached' if branch == 'HEAD'

        branch
      end

      def current_commit
        run_git('rev-parse', 'HEAD').strip
      end

      def remote_head(remote: 'origin', branch: nil)
        branch ||= current_branch
        run_git('rev-parse', "#{remote}/#{branch}").strip
      rescue GitError
        nil
      end

      def remote?(remote: 'origin')
        run_git('remote', 'get-url', remote)
        true
      rescue GitError
        false
      end

      def clean?
        run_git('status', '--porcelain').strip.empty?
      end

      def file_exists_at_commit?(commit:, path:)
        run_git('cat-file', '-e', "#{commit}:#{path}")
        true
      rescue GitError
        false
      end

      # ------------------------------------------------------------------
      # Content Retrieval
      # ------------------------------------------------------------------
      # Methods that retrieve file contents from specific commits.
      # Unlike query methods, these raise on failure since a missing
      # file is typically an error condition.

      def show_file_at_commit(commit:, path:)
        run_git('show', "#{commit}:#{path}")
      rescue GitError => e
        raise GitError.new('File not found at commit', command: e.command, stderr: e.stderr, exit_code: e.exit_code)
      end

      # ------------------------------------------------------------------
      # Basic Git Operations
      # ------------------------------------------------------------------
      # Standard git commands (fetch, pull, push, add, commit, etc).
      # These modify repository state and raise GitError on failure.

      def fetch(remote: 'origin')
        run_git('fetch', remote)
      end

      def pull(remote: 'origin', branch: nil)
        args = ['pull', remote]
        args << branch if branch
        run_git(*args)
      end

      def push(remote: 'origin', branch: nil)
        args = ['push', remote]
        args << branch if branch
        run_git(*args)
      end

      def add(paths:)
        paths = Array(paths).reject { |p| p.nil? || p.to_s.strip.empty? }
        raise ArgumentError, 'No paths provided to add' if paths.empty?

        run_git('add', *paths)
      end

      def commit(message:)
        raise ArgumentError, 'Commit message cannot be empty' if message.nil? || message.strip.empty?

        run_git('commit', '-m', message)
      end

      def merge_base(commit1, commit2)
        run_git('merge-base', commit1, commit2).strip
      rescue GitError
        nil
      end

      def diff_files(from:, to:)
        output = run_git('diff', '--name-only', from, to)
        output.lines.map(&:strip).reject(&:empty?)
      end

      def log(ref: 'HEAD', count: 1, format: '%H')
        run_git('log', "-#{count}", "--format=#{format}", ref)
      end

      # ------------------------------------------------------------------
      # Branch Operations
      # ------------------------------------------------------------------
      # Create, check, and checkout branches. All branch names are
      # validated against git-check-ref-format rules before use.
      # Raises BranchError for invalid names or failed operations.

      def branch_exists?(branch, remote: nil)
        BranchError.validate_branch_name!(branch)

        if remote
          run_git('ls-remote', '--heads', remote, branch)
            .lines.any? { |line| line.end_with?("refs/heads/#{branch}\n") || line.end_with?("refs/heads/#{branch}") }
        else
          run_git('rev-parse', '--verify', "refs/heads/#{branch}")
          true
        end
      rescue BranchError
        raise
      rescue GitError
        false
      end

      def create_orphan_branch(branch, initial_message: 'Initialize branch')
        BranchError.validate_branch_name!(branch)
        raise BranchError, "Branch '#{branch}' already exists" if branch_exists?(branch)

        run_git('checkout', '--orphan', branch)
        run_git('rm', '-rf', '.', allow_failure: true)
        run_git('commit', '--allow-empty', '-m', initial_message)
      rescue GitError => e
        raise BranchError.new("Failed to create orphan branch '#{branch}': #{e.message}",
                              command: e.command, stderr: e.stderr, exit_code: e.exit_code)
      end

      def checkout(branch, create: false)
        BranchError.validate_branch_name!(branch)

        if create
          run_git('checkout', '-b', branch)
        else
          run_git('checkout', branch)
        end
      rescue GitError => e
        raise BranchError.new("Failed to checkout branch '#{branch}': #{e.message}",
                              command: e.command, stderr: e.stderr, exit_code: e.exit_code)
      end

      # ------------------------------------------------------------------
      # Ledger Branch Operations
      # ------------------------------------------------------------------
      # Network-aware operations for syncing the ledger branch with a
      # remote. The "ledger" is a dedicated orphan branch that stores
      # atom claim state, allowing multiple agents to coordinate work
      # without conflicts on the main branch.
      #
      # These methods have configurable timeouts since network operations
      # can hang indefinitely on unreliable connections.

      def fetch_branch(remote:, branch:, timeout: DEFAULT_NETWORK_TIMEOUT)
        BranchError.validate_branch_name!(branch)
        run_git_with_timeout('fetch', remote, branch, timeout: timeout)
      rescue GitTimeoutError
        raise
      rescue GitError => e
        raise BranchError.new("Failed to fetch '#{branch}' from '#{remote}': #{e.message}",
                              command: e.command, stderr: e.stderr, exit_code: e.exit_code)
      end

      def push_branch(remote:, branch:, set_upstream: false, timeout: DEFAULT_NETWORK_TIMEOUT)
        BranchError.validate_branch_name!(branch)

        args = ['push']
        args << '-u' if set_upstream
        args << remote << branch
        run_git_with_timeout(*args, timeout: timeout)
      rescue GitTimeoutError
        raise
      rescue GitError => e
        raise BranchError.new("Failed to push '#{branch}' to '#{remote}': #{e.message}",
                              command: e.command, stderr: e.stderr, exit_code: e.exit_code)
      end

      # Returns the SHA of a branch on a remote, or nil if not found.
      #
      # Unlike #remote_head which uses local tracking refs (requires fetch),
      # this queries the remote directly via ls-remote.
      #
      # @param remote [String] Remote name (e.g., 'origin')
      # @param branch [String] Branch name to look up
      # @return [String, nil] The commit SHA, or nil if branch doesn't exist
      def remote_branch_sha(remote:, branch:)
        BranchError.validate_branch_name!(branch)

        output = run_git('ls-remote', remote, "refs/heads/#{branch}")
        return nil if output.strip.empty?

        output.split("\t").first
      rescue BranchError
        raise
      rescue GitError
        nil
      end

      private

      def run_git(*args, allow_failure: false)
        command = ['git', '-C', repo_path, *args]
        stdout, stderr, status = Open3.capture3(*command)

        unless status.success? || allow_failure
          raise GitError.new(
            stderr.strip.empty? ? 'Git command failed' : stderr.strip,
            command: command.join(' '),
            stderr: stderr,
            exit_code: status.exitstatus
          )
        end

        stdout
      end
    end
  end
end
