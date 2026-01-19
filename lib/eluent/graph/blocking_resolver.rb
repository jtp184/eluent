# frozen_string_literal: true

module Eluent
  module Graph
    # Resolves blocking status for atoms considering all dependency types
    class BlockingResolver
      # Pattern for failure close reasons
      FAILURE_PATTERN = /^(fail|error|abort)/i

      def initialize(indexer:, dependency_graph:)
        @indexer = indexer
        @dependency_graph = dependency_graph
        @cache = {}
      end

      # Returns { blocked: bool, blockers: [...] } where blockers are bond objects
      def blocked?(atom)
        return { blocked: false, blockers: [] } if atom.nil?

        cached = cache[atom.id]
        return cached if cached

        blockers = []

        # Check direct blocking bonds
        indexer.bonds_to(atom.id).each do |bond|
          next unless bond.blocking?

          source = indexer.find_by_id(bond.source_id)
          next unless source

          blocker = check_bond_blocking(bond, source)
          blockers << bond if blocker
        end

        # Check parent chain for parent_child blocking
        if atom.parent_id
          parent = indexer.find_by_id(atom.parent_id)
          if parent && blocking_parent?(parent)
            # Create synthetic bond to represent parent blocking
            parent_bond = Models::Bond.new(
              source_id: parent.id,
              target_id: atom.id,
              dependency_type: :parent_child
            )
            blockers << parent_bond
          end
        end

        cache[atom.id] = { blocked: blockers.any?, blockers: blockers }
      end

      # Combines blocking check with abstract and defer_until checks
      def ready?(atom, include_abstract: false)
        return false if atom.nil?
        return false if atom.abstract? && !include_abstract
        return false if atom.closed? || atom.discard?
        return false if atom.defer_future?
        return false if blocked?(atom)[:blocked]

        true
      end

      # Clear per-request cache
      def clear_cache
        @cache = {}
      end

      private

      attr_reader :indexer, :dependency_graph, :cache

      def check_bond_blocking(bond, source)
        case bond.dependency_type.name
        when :blocks then blocking_by_blocks?(source)
        when :parent_child then blocking_by_parent_child?(source)
        when :conditional_blocks then blocking_by_conditional?(source)
        when :waits_for then blocking_by_waits_for?(source, exclude_id: bond.target_id)
        else false
        end
      end

      # blocks: Blocked if source is not closed
      def blocking_by_blocks?(source)
        !source.closed?
      end

      # parent_child: Blocked if parent is not closed (recursive via blocking_parent?)
      def blocking_by_parent_child?(source)
        !source.closed?
      end

      # conditional_blocks: Blocked only if source failed
      def blocking_by_conditional?(source)
        return false unless source.closed?

        source.close_reason && FAILURE_PATTERN.match?(source.close_reason)
      end

      # waits_for: Blocked until source AND all its descendants are closed
      # exclude_id is used to exclude the target being checked from descendants
      def blocking_by_waits_for?(source, exclude_id: nil)
        return true unless source.closed?

        # Check all descendants are also closed (excluding the target itself)
        descendants = dependency_graph.all_descendants(source.id, blocking_only: true)
        descendants.delete(exclude_id) if exclude_id
        descendants.any? do |desc_id|
          desc = indexer.find_by_id(desc_id)
          desc && !desc.closed?
        end
      end

      # Recursively check parent chain for blocking
      def blocking_parent?(parent)
        return false if parent.nil?
        return false if parent.closed?
        return true unless parent.parent_id

        # Parent is open, so check if grandparent also blocks
        grandparent = indexer.find_by_id(parent.parent_id)
        grandparent.nil? || blocking_parent?(grandparent)
      end
    end
  end
end
