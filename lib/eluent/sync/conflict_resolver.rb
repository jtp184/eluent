# frozen_string_literal: true

module Eluent
  module Sync
    # Resolves conflicts during 3-way merge
    # Single responsibility: conflict resolution strategies
    class ConflictResolver
      RESOLUTION_KEEP_LOCAL = :keep_local
      RESOLUTION_KEEP_REMOTE = :keep_remote
      RESOLUTION_MERGE = :merge
      RESOLUTION_DELETE = :delete

      # Resurrection rule: edit wins over delete
      # Returns: :keep_local | :keep_remote | :merge | :delete
      def resolve_atom_conflict(base:, local:, remote:)
        local_discarded = local&.discard?
        remote_discarded = remote&.discard?

        # Both discarded - delete
        return RESOLUTION_DELETE if local_discarded && remote_discarded

        # Local discarded, remote edited (resurrection rule)
        if local_discarded && !remote_discarded
          return resurrection_check(base: base, edited: remote) ? RESOLUTION_KEEP_REMOTE : RESOLUTION_DELETE
        end

        # Remote discarded, local edited (resurrection rule)
        if remote_discarded && !local_discarded
          return resurrection_check(base: base, edited: local) ? RESOLUTION_KEEP_LOCAL : RESOLUTION_DELETE
        end

        # Neither discarded - merge
        RESOLUTION_MERGE
      end

      # Comment deduplication using existing Comment#dedup_key
      # Keeps earliest by created_at when duplicates found
      def deduplicate_comments(comments)
        comments
          .group_by(&:dedup_key)
          .values
          .map { |group| group.min_by { |c| c.created_at || Time.now.utc } }
      end

      # Bond deduplication by (source_id, target_id, dependency_type)
      # Uses existing Bond#key method
      def deduplicate_bonds(bonds)
        bonds.uniq(&:key)
      end

      private

      # Resurrection check: was the item edited after base?
      # If edited has newer updated_at than base, resurrect
      def resurrection_check(base:, edited:)
        return true if base.nil? # New item on one side
        return true if edited.nil? # Shouldn't happen, but safe

        base_time = base.updated_at || Time.at(0).utc
        edited_time = edited.updated_at || Time.at(0).utc

        edited_time > base_time
      end
    end
  end
end
