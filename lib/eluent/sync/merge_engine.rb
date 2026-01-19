# frozen_string_literal: true

module Eluent
  module Sync
    # 3-way merge algorithm for sync
    # Single responsibility: merge base, local, and remote states
    class MergeEngine
      # Scalar fields use Last-Write-Wins (LWW) by updated_at.
      # These represent single values where only one can be "correct" - when both sides
      # modify the same field, we take the most recent change.
      SCALAR_FIELDS = %i[title description status issue_type priority assignee parent_id defer_until
                         close_reason].freeze

      # Set fields use union merge with deletion tracking.
      # Labels are additive by nature - both sides can add labels independently,
      # and explicit removals should be preserved.
      SET_FIELDS = %i[labels].freeze

      # Deep merge fields recurse into nested hashes.
      # Metadata is extensible key-value data where different keys can be
      # modified independently by each side.
      DEEP_MERGE_FIELDS = %i[metadata].freeze

      MergeResult = Struct.new(:atoms, :bonds, :comments, :conflicts, keyword_init: true)

      def initialize(conflict_resolver: ConflictResolver.new)
        @conflict_resolver = conflict_resolver
      end

      # Main entry point
      # Each input is a hash with :atoms, :bonds, :comments arrays
      # Returns MergeResult
      def merge(base:, local:, remote:)
        merged_atoms, atom_conflicts = merge_atoms(
          base_atoms: base[:atoms] || [],
          local_atoms: local[:atoms] || [],
          remote_atoms: remote[:atoms] || []
        )

        merged_bonds = merge_bonds(
          _base_bonds: base[:bonds] || [],
          local_bonds: local[:bonds] || [],
          remote_bonds: remote[:bonds] || []
        )

        merged_comments = merge_comments(
          _base_comments: base[:comments] || [],
          local_comments: local[:comments] || [],
          remote_comments: remote[:comments] || []
        )

        MergeResult.new(
          atoms: merged_atoms,
          bonds: merged_bonds,
          comments: merged_comments,
          conflicts: atom_conflicts
        )
      end

      private

      attr_reader :conflict_resolver

      def merge_atoms(base_atoms:, local_atoms:, remote_atoms:)
        base_by_id = index_by_id(base_atoms)
        local_by_id = index_by_id(local_atoms)
        remote_by_id = index_by_id(remote_atoms)

        all_ids = (base_by_id.keys + local_by_id.keys + remote_by_id.keys).uniq

        merged = []
        conflicts = []

        all_ids.each do |id|
          base = base_by_id[id]
          local = local_by_id[id]
          remote = remote_by_id[id]

          result = resolve_atom_outcome(base: base, local: local, remote: remote)

          case result
          in { atom: atom } if atom
            merged << atom
          in { conflict: conflict }
            conflicts << conflict
          else
            # Deleted or resolved to nil
          end
        end

        [merged, conflicts]
      end

      # Decides what to do with an atom: keep local, keep remote, merge, or delete.
      # Returns a hash with :atom key (the result) or :conflict key (if unresolvable).
      def resolve_atom_outcome(base:, local:, remote:)
        # New in local only
        return { atom: local } if base.nil? && remote.nil? && local

        # New in remote only
        return { atom: remote } if base.nil? && local.nil? && remote

        # Deleted in both or never existed
        return { atom: nil } if local.nil? && remote.nil?

        # Both have it - check for conflicts
        resolution = conflict_resolver.resolve_atom_conflict(base: base, local: local, remote: remote)

        case resolution
        when ConflictResolver::RESOLUTION_DELETE
          { atom: nil }
        when ConflictResolver::RESOLUTION_KEEP_LOCAL
          { atom: local }
        when ConflictResolver::RESOLUTION_KEEP_REMOTE
          { atom: remote }
        when ConflictResolver::RESOLUTION_MERGE
          { atom: build_merged_atom(base: base, local: local, remote: remote) }
        end
      end

      # Constructs a new merged atom by combining fields from base, local, and remote.
      # Uses different strategies per field type: LWW for scalars, union for sets, deep merge for metadata.
      def build_merged_atom(base:, local:, remote:)
        # Build merged hash starting from local as base
        merged_attrs = { id: local.id }

        # Merge scalar fields with LWW
        SCALAR_FIELDS.each do |field|
          merged_attrs[field] = merge_scalar(
            field: field,
            base: base,
            local: local,
            remote: remote
          )
        end

        # Merge set fields with union
        SET_FIELDS.each do |field|
          merged_attrs[field] = merge_set(
            field: field,
            base: base,
            local: local,
            remote: remote
          )
        end

        # Merge metadata with deep merge
        merged_attrs[:metadata] = deep_merge_metadata(
          base: base&.metadata || {},
          local: local.metadata || {},
          remote: remote&.metadata || {}
        )

        # Preserve timestamps - take latest updated_at
        merged_attrs[:created_at] = local.created_at
        merged_attrs[:updated_at] = [local.updated_at, remote&.updated_at].compact.max

        Models::Atom.new(**merged_attrs)
      end

      # Merge scalar field using precedence order:
      # 1. If no remote exists, use local (local-only change)
      # 2. If values match, use either (no conflict)
      # 3. If local unchanged from base, use remote (remote modified it)
      # 4. If remote unchanged from base, use local (local modified it)
      # 5. If both changed, use Last-Write-Wins by updated_at timestamp
      def merge_scalar(field:, base:, local:, remote:)
        local_val = local.send(field)
        remote_val = remote&.send(field)
        base_val = base&.send(field)

        # 1. No remote - use local
        return local_val if remote.nil?

        # 2. Values are the same - no conflict
        return local_val if values_equal?(local_val, remote_val)

        # 3. Local unchanged from base - take remote
        return remote_val if values_equal?(local_val, base_val)

        # 4. Remote unchanged from base - take local
        return local_val if values_equal?(remote_val, base_val)

        # 5. Both changed - LWW by updated_at
        local_time = local.updated_at || ConflictResolver::FALLBACK_TIME
        remote_time = remote.updated_at || ConflictResolver::FALLBACK_TIME

        remote_time > local_time ? remote_val : local_val
      end

      def merge_set(field:, base:, local:, remote:)
        local_set = Set.new(Array(local.send(field)))
        remote_set = Set.new(Array(remote&.send(field)))
        base_set = Set.new(Array(base&.send(field)))

        # Union: keep all labels that exist in either local or remote
        # But remove labels that were explicitly removed (in base but not in local/remote)
        local_added = local_set - base_set
        remote_added = remote_set - base_set
        local_removed = base_set - local_set
        remote_removed = base_set - remote_set

        # Start with base, add new ones, remove deleted ones
        result = base_set.dup
        result.merge(local_added)
        result.merge(remote_added)
        result.subtract(local_removed)
        result.subtract(remote_removed)

        result.to_a
      end

      # Deep merge metadata hashes with remote-wins precedence.
      # Processing order determines conflict resolution:
      # 1. Start with base (common ancestor)
      # 2. Apply local changes (overwrites base)
      # 3. Apply remote changes (overwrites local for same keys)
      # This gives remote the final say on conflicting scalar keys,
      # while nested hashes recurse to merge their contents.
      def deep_merge_metadata(base:, local:, remote:)
        merged = deep_dup_hash(base)

        # Apply local changes over base
        local.each do |k, v|
          merged[k] = v
        end

        # Apply remote changes over local (remote wins on conflicts)
        remote.each do |k, v|
          merged[k] = if merged.key?(k) && merged[k].is_a?(Hash) && v.is_a?(Hash)
                        # Both sides have nested hash - recurse to merge contents
                        deep_merge_metadata(base: base[k] || {}, local: merged[k], remote: v)
                      else
                        # Scalar value - remote wins since it's processed last
                        v
                      end
        end

        merged
      end

      def merge_bonds(_base_bonds:, local_bonds:, remote_bonds:)
        # Union of all bonds, deduplicated by key
        # _base_bonds reserved for future diff-based merge
        all_bonds = local_bonds + remote_bonds
        conflict_resolver.deduplicate_bonds(all_bonds)
      end

      def merge_comments(_base_comments:, local_comments:, remote_comments:)
        # Union of all comments, deduplicated by dedup_key
        # _base_comments reserved for future diff-based merge
        all_comments = local_comments + remote_comments
        conflict_resolver.deduplicate_comments(all_comments)
      end

      def index_by_id(items)
        items.each_with_object({}) { |item, hash| hash[item.id] = item }
      end

      def values_equal?(val1, val2)
        # Handle Status/IssueType comparison
        normalize_for_compare(val1) == normalize_for_compare(val2)
      end

      def normalize_for_compare(val)
        case val
        when Models::Status, Models::IssueType, Models::DependencyType
          val.to_sym
        when Set
          val.to_a.sort
        else
          val
        end
      end

      def deep_dup_hash(hash)
        hash.transform_values do |v|
          v.is_a?(Hash) ? deep_dup_hash(v) : v
        end
      end
    end
  end
end
