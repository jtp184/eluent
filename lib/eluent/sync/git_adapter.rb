# frozen_string_literal: true

require 'open3'

module Eluent
  module Sync
    # Wrapper for Git CLI operations
    # Single responsibility: execute git commands safely
    class GitAdapter
      attr_reader :repo_path

      def initialize(repo_path:)
        @repo_path = File.expand_path(repo_path)
      end

      # --- Query Methods ---

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

      def has_remote?(remote: 'origin')
        run_git('remote', 'get-url', remote, allow_failure: true)
        true
      rescue GitError
        false
      end

      def clean?
        run_git('status', '--porcelain').strip.empty?
      end

      def file_exists_at_commit?(commit:, path:)
        run_git('cat-file', '-e', "#{commit}:#{path}", allow_failure: true)
        true
      rescue GitError
        false
      end

      # --- Content Retrieval ---

      def show_file_at_commit(commit:, path:)
        run_git('show', "#{commit}:#{path}")
      rescue GitError => e
        raise GitError.new('File not found at commit', command: e.command, stderr: e.stderr, exit_code: e.exit_code)
      end

      # --- Operations ---

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
        run_git('add', *Array(paths))
      end

      def commit(message:)
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

    # Error raised when a git command fails
    class GitError < Error
      attr_reader :command, :stderr, :exit_code

      def initialize(message, command: nil, stderr: nil, exit_code: nil)
        super(message)
        @command = command
        @stderr = stderr
        @exit_code = exit_code
      end
    end

    # Error raised when no remote is configured
    class NoRemoteError < GitError
      def initialize(message = 'No remote configured')
        super
      end
    end

    # Error raised when HEAD is detached
    class DetachedHeadError < GitError
      def initialize(message = 'Cannot sync: HEAD is detached')
        super
      end
    end
  end
end
