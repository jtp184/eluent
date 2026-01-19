# frozen_string_literal: true

require 'json'

module Eluent
  module Sync
    # Coordinates the sync workflow
    # Single responsibility: orchestrate pull-first sync process
    class PullFirstOrchestrator
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

      # Main entry point
      def sync(pull_only: false, push_only: false, dry_run: false, force: false)
        validate_remote!

        return push_changes(dry_run: dry_run, force: force) if push_only

        git_adapter.fetch

        remote_head = git_adapter.remote_head
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

        # Apply merged result
        apply_merge_result(merge_result)

        # Update sync state
        new_local_head = git_adapter.current_commit
        sync_state.update(
          last_sync_at: Time.now.utc,
          base_commit: remote_head,
          local_head: new_local_head,
          remote_head: remote_head
        ).save

        # Push if not pull_only
        commits = []
        unless pull_only
          if git_adapter.clean?
            # No local changes to push
          else
            commit_hash = commit_changes(force: force)
            commits << commit_hash if commit_hash
            git_adapter.push
          end
        end

        SyncResult.new(
          status: merge_result.conflicts.any? ? :conflicted : :success,
          changes: compute_changes(local_state, merge_result),
          conflicts: merge_result.conflicts,
          commits: commits
        )
      end

      private

      attr_reader :repository, :git_adapter, :sync_state, :merge_engine

      def validate_remote!
        raise NoRemoteError unless git_adapter.has_remote?
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
        { atoms: [], bonds: [], comments: [] }
      end

      def parse_jsonl_content(content)
        atoms = []
        bonds = []
        comments = []

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
        rescue JSON::ParserError
          # Skip malformed lines
        end

        { atoms: atoms.compact, bonds: bonds.compact, comments: comments.compact }
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

      def compute_changes(local_state, merge_result)
        changes = []

        local_ids = Set.new(local_state[:atoms].map(&:id))
        merged_ids = Set.new(merge_result.atoms.map(&:id))

        # Added atoms
        (merged_ids - local_ids).each do |id|
          atom = merge_result.atoms.find { |a| a.id == id }
          changes << { type: :added, record_type: :atom, id: id, title: atom&.title }
        end

        # Removed atoms
        (local_ids - merged_ids).each do |id|
          atom = local_state[:atoms].find { |a| a.id == id }
          changes << { type: :removed, record_type: :atom, id: id, title: atom&.title }
        end

        # Modified atoms
        (local_ids & merged_ids).each do |id|
          local = local_state[:atoms].find { |a| a.id == id }
          merged = merge_result.atoms.find { |a| a.id == id }
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
        '.eluent/data.jsonl'
      end
    end
  end
end
