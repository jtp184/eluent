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

      # Fallback timestamp for nil created_at/updated_at comparisons.
      # Using epoch ensures deterministic ordering when timestamps are missing.
      FALLBACK_TIME = Time.at(0).utc.freeze

      # Resurrection rule: When one side deletes an item and the other edits it,
      # the edit wins if it occurred after the base version. This prevents
      # accidental data loss when edits and deletes happen concurrently.
      #
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

      # Comment deduplication using existing Comment#dedup_key.
      # Keeps earliest by created_at when duplicates found.
      # Uses FALLBACK_TIME for nil created_at for deterministic ordering.
      def deduplicate_comments(comments)
        comments
          .group_by(&:dedup_key)
          .values
          .map { |group| group.min_by { |c| c.created_at || FALLBACK_TIME } }
      end

      # Bond deduplication by (source_id, target_id, dependency_type)
      # Uses existing Bond#key method
      def deduplicate_bonds(bonds)
        bonds.uniq(&:key)
      end

      private

      # Resurrection check: was the item edited after base?
      # If edited has newer updated_at than base, resurrect.
      def resurrection_check(base:, edited:)
        return true if base.nil? # New item on one side
        return true if edited.nil? # Shouldn't happen, but safe

        base_time = base.updated_at || FALLBACK_TIME
        edited_time = edited.updated_at || FALLBACK_TIME

        edited_time > base_time
      end
    end
  end
end
