# frozen_string_literal: true

require 'fileutils'
require 'json'

module Eluent
  module Sync
    # Error raised when a sync operation is already in progress
    class SyncInProgressError < Error; end

    # Coordinates the sync workflow
    # Single responsibility: orchestrate pull-first sync process
    class PullFirstOrchestrator
      # Result of a sync operation.
      # Status values:
      #   :success    - Sync completed, changes were merged and/or pushed
      #   :up_to_date - No changes needed, local and remote are in sync
      #   :conflicted - Sync completed but unresolved conflicts remain
      SyncResult = Struct.new(:status, :changes, :conflicts, :commits, keyword_init: true) do
        def success? = status == :success
        def up_to_date? = status == :up_to_date
        def conflicted? = status == :conflicted
      end

      def initialize(repository:, git_adapter:, sync_state:)
        @repository = repository
        @git_adapter = git_adapter
        @sync_state = sync_state
        @merge_engine = MergeEngine.new
      end

      # Main entry point for sync operations.
      #
      # @param pull_only [Boolean] Only pull remote changes, don't push local changes.
      # @param push_only [Boolean] Only push local changes, skip pull/merge.
      #   Note: pull_only and push_only are mutually exclusive. If both are false,
      #   performs a full bidirectional sync (pull, merge, push).
      # @param dry_run [Boolean] Compute what would change without writing to disk.
      # @param force [Boolean] Bypass safety checks (e.g., in-progress items warning).
      # @return [SyncResult] The outcome of the sync operation.
      def sync(pull_only: false, push_only: false, dry_run: false, force: false)
        with_sync_lock do
          perform_sync(pull_only: pull_only, push_only: push_only, dry_run: dry_run, force: force)
        end
      end

      private

      def perform_sync(pull_only:, push_only:, dry_run:, force:)
        raise ArgumentError, 'Cannot use both pull_only and push_only' if pull_only && push_only

        validate_remote!

        return push_changes(dry_run: dry_run, force: force) if push_only

        git_adapter.fetch

        remote_head = git_adapter.remote_head
        raise NoRemoteError, 'Remote branch not found' if remote_head.nil?

        local_head = git_adapter.current_commit
        base_commit = sync_state.base_commit || find_merge_base(local_head, remote_head)

        # Check if up to date
        if remote_head == local_head && sync_state.base_commit
          return SyncResult.new(status: :up_to_date, changes: [], conflicts: [], commits: [])
        end

        # Load states
        base_state = load_state_at_commit(base_commit)
        local_state = load_current_state
        remote_state = load_state_at_commit(remote_head)

        # Merge
        merge_result = merge_engine.merge(base: base_state, local: local_state, remote: remote_state)

        if dry_run
          return SyncResult.new(
            status: merge_result.conflicts.any? ? :conflicted : :success,
            changes: compute_changes(local_state, merge_result),
            conflicts: merge_result.conflicts,
            commits: []
          )
        end

        # Apply merged result with rollback on failure
        apply_with_rollback(merge_result, pull_only: pull_only, force: force, remote_head: remote_head)
      end

      def apply_with_rollback(merge_result, pull_only:, force:, remote_head:)
        data_path = repository.paths.data_file
        backup_path = "#{data_path}.backup"
        local_state = load_current_state

        FileUtils.cp(data_path, backup_path) if File.exist?(data_path)

        begin
          apply_merge_result(merge_result)
          commits = push_if_needed(pull_only: pull_only, force: force)
          update_sync_state(remote_head)

          SyncResult.new(
            status: merge_result.conflicts.any? ? :conflicted : :success,
            changes: compute_changes(local_state, merge_result),
            conflicts: merge_result.conflicts,
            commits: commits
          )
        rescue StandardError
          FileUtils.mv(backup_path, data_path) if File.exist?(backup_path)
          raise
        ensure
          FileUtils.rm_f(backup_path)
        end
      end

      def push_if_needed(pull_only:, force:)
        return [] if pull_only || git_adapter.clean?

        commit_hash = commit_changes(force: force)
        git_adapter.push
        commit_hash ? [commit_hash] : []
      end

      def update_sync_state(remote_head)
        sync_state.update(
          last_sync_at: Time.now.utc,
          base_commit: remote_head,
          local_head: git_adapter.current_commit,
          remote_head: remote_head
        ).save
      end

      def with_sync_lock
        lock_file = File.join(repository.paths.eluent_dir, '.sync.lock')
        FileUtils.mkdir_p(File.dirname(lock_file))

        File.open(lock_file, File::CREAT | File::RDWR) do |f|
          unless f.flock(File::LOCK_EX | File::LOCK_NB)
            raise SyncInProgressError, 'Another sync operation is in progress'
          end

          yield
        end
      end

      attr_reader :repository, :git_adapter, :sync_state, :merge_engine

      def validate_remote!
        raise NoRemoteError unless git_adapter.remote?
      end

      def find_merge_base(commit1, commit2)
        git_adapter.merge_base(commit1, commit2) || commit1
      end

      def load_state_at_commit(commit)
        return empty_state if commit.nil?

        begin
          content = git_adapter.show_file_at_commit(
            commit: commit,
            path: relative_data_path
          )
          parse_jsonl_content(content)
        rescue GitError
          empty_state
        end
      end

      def load_current_state
        path = repository.paths.data_file
        return empty_state unless File.exist?(path)

        parse_jsonl_file(path)
      end

      def empty_state
        { atoms: [], bonds: [], comments: [], skipped: 0 }
      end

      def parse_jsonl_content(content)
        atoms = []
        bonds = []
        comments = []
        skipped_count = 0

        content.each_line do |line|
          next if line.strip.empty?

          data = JSON.parse(line, symbolize_names: true)
          case data[:_type]
          when 'atom'
            atoms << Storage::Serializers::AtomSerializer.deserialize(data)
          when 'bond'
            bonds << Storage::Serializers::BondSerializer.deserialize(data)
          when 'comment'
            comments << Storage::Serializers::CommentSerializer.deserialize(data)
          end
        rescue JSON::ParserError => e
          skipped_count += 1
          warn "el: warning: skipping malformed JSON line during sync: #{e.message}"
        end

        warn "el: WARNING: #{skipped_count} record(s) skipped due to data corruption" if skipped_count.positive?

        { atoms: atoms.compact, bonds: bonds.compact, comments: comments.compact, skipped: skipped_count }
      end

      def parse_jsonl_file(path)
        parse_jsonl_content(File.read(path))
      end

      def apply_merge_result(merge_result)
        path = repository.paths.data_file

        # Build header
        header = {
          _type: 'header',
          repo_name: repository.repo_name,
          generator: "eluent/#{Eluent::VERSION}",
          created_at: Time.now.utc.iso8601
        }

        # Build records
        records = [header]
        merge_result.atoms.each { |atom| records << atom.to_h }
        merge_result.bonds.each { |bond| records << bond.to_h }
        merge_result.comments.each { |comment| records << comment.to_h }

        # Write atomically
        Storage::FileOperations.write_records_atomically(path, records)

        # Reload repository index
        repository.load!
      end

      def commit_changes(force: false)
        # Check for in-progress items unless force
        unless force
          in_progress = repository.list_atoms(status: 'in_progress')
          warn "el: warning: #{in_progress.size} items in progress, use --force to sync anyway" if in_progress.any?
        end

        git_adapter.add(paths: [relative_data_path])
        git_adapter.commit(message: "[eluent] sync: #{Time.now.utc.iso8601}")
        git_adapter.current_commit
      rescue GitError => e
        # Commit might fail if nothing to commit
        return nil if e.message.include?('nothing to commit')

        raise
      end

      def push_changes(dry_run:, force:)
        return SyncResult.new(status: :success, changes: [], conflicts: [], commits: []) if dry_run

        commit_hash = commit_changes(force: force)
        git_adapter.push if commit_hash

        SyncResult.new(
          status: :success,
          changes: [],
          conflicts: [],
          commits: commit_hash ? [commit_hash] : []
        )
      end

      # Computes the diff between local state and merge result to report what changed.
      # Uses hash lookups for O(n) performance instead of O(n²) find loops.
      def compute_changes(local_state, merge_result)
        changes = []

        local_by_id = local_state[:atoms].to_h { |a| [a.id, a] }
        merged_by_id = merge_result.atoms.to_h { |a| [a.id, a] }

        local_ids = Set.new(local_by_id.keys)
        merged_ids = Set.new(merged_by_id.keys)

        # Set difference: IDs in merged but not in local = atoms added from remote
        (merged_ids - local_ids).each do |id|
          atom = merged_by_id[id]
          changes << { type: :added, record_type: :atom, id: id, title: atom&.title }
        end

        # Set difference: IDs in local but not in merged = atoms removed (deleted remotely or via merge)
        (local_ids - merged_ids).each do |id|
          atom = local_by_id[id]
          changes << { type: :removed, record_type: :atom, id: id, title: atom&.title }
        end

        # Set intersection: IDs in both = atoms that may have been modified
        (local_ids & merged_ids).each do |id|
          local = local_by_id[id]
          merged = merged_by_id[id]
          next if atoms_equal?(local, merged)

          changes << { type: :modified, record_type: :atom, id: id, title: merged&.title }
        end

        changes
      end

      def atoms_equal?(atom1, atom2)
        return true if atom1.nil? && atom2.nil?
        return false if atom1.nil? || atom2.nil?

        atom1.to_h == atom2.to_h
      end

      def relative_data_path
        File.join(Storage::Paths::ELUENT_DIR, Storage::Paths::DATA_FILE)
      end
    end
  end
end
