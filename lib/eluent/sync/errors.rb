# frozen_string_literal: true

module Eluent
  module Sync
    # ------------------------------------------------------------------
    # Error Classes
    # ------------------------------------------------------------------
    # Hierarchy: Error > GitError > (specialized errors)
    #
    # All git errors include diagnostic information:
    # - command: The full git command that was executed
    # - stderr: The error output from git
    # - exit_code: The process exit code

    # Base error for all git command failures.
    # Includes the command, stderr, and exit code for debugging.
    class GitError < Error
      attr_reader :command, :stderr, :exit_code

      def initialize(message, command: nil, stderr: nil, exit_code: nil)
        super(message)
        @command = command
        @stderr = stderr
        @exit_code = exit_code
      end
    end

    # Raised when a required remote (e.g., 'origin') is not configured.
    # This typically means the repository was cloned without --origin or
    # the remote was removed.
    class NoRemoteError < GitError
      def initialize(message = 'No remote configured')
        super
      end
    end

    # Raised when attempting operations that require a branch, but HEAD
    # is detached (pointing directly at a commit, not a branch).
    # Common after `git checkout <commit>` or during rebase/bisect.
    class DetachedHeadError < GitError
      def initialize(message = 'Cannot sync: HEAD is detached')
        super
      end
    end

    # Raised when worktree operations fail (add, remove, list, etc).
    # Worktrees are separate working directories sharing the same repo.
    class WorktreeError < GitError
    end

    # Raised when branch operations fail or branch names are invalid.
    # Includes validation logic matching git-check-ref-format rules.
    class BranchError < GitError
      # Character class for valid branch name characters.
      # Based on git-check-ref-format(1) rules:
      # - No ASCII control characters (0x00-0x1F, 0x7F)
      # - No space, ~, ^, :, ?, *, [, or backslash
      VALID_BRANCH_CHAR_CLASS = /\A[^\x00-\x1f\x7f ~^:?*\[\\]+\z/

      class << self
        # Validates a branch name, raising BranchError if invalid.
        # @param name [String] Branch name to validate
        # @raise [BranchError] if the name violates git-check-ref-format rules
        def validate_branch_name!(name)
          return if valid_branch_name?(name)

          raise new("Invalid branch name: '#{name}'")
        end

        # Checks if a branch name is valid per git-check-ref-format rules.
        # @param name [String] Branch name to check
        # @return [Boolean] true if valid
        def valid_branch_name?(name)
          return false if name.nil? || name.empty?
          return false unless name.match?(VALID_BRANCH_CHAR_CLASS)
          return false if name.start_with?('-')      # Can't start with dash (looks like option)
          return false if name.include?('..')        # Reserved for revision ranges
          return false if name.include?('@{')        # Reserved for reflog syntax
          return false if name.include?('//')        # No empty path components
          return false if name.end_with?('/')        # No trailing slash
          return false if name.end_with?('.')        # No trailing dot
          return false if name.end_with?('.lock')    # Reserved by git for lock files
          return false if name == '@'                # Reserved (alias for HEAD)
          return false if name.start_with?('/')      # No leading slash

          true
        end
      end
    end

    # Raised when a network git operation (fetch, push) exceeds its timeout.
    # Includes the timeout value that was exceeded.
    class GitTimeoutError < GitError
      attr_reader :timeout

      def initialize(message, timeout: nil, **)
        super(message, **)
        @timeout = timeout
      end
    end
  end
end
