# frozen_string_literal: true

module Eluent
  module Graph
    # DAG traversal operations for dependency relationships
    class DependencyGraph
      def initialize(indexer)
        @indexer = indexer
      end

      # DFS to check if a path exists from source to target
      def path_exists?(source_id, target_id, blocking_only: true)
        return false if source_id.nil? || target_id.nil?

        visited = Set.new
        stack = [source_id]

        while (current = stack.pop)
          next if visited.include?(current)

          return true if current == target_id

          visited.add(current)
          outgoing_bonds(current, blocking_only: blocking_only).each do |bond|
            stack.push(bond.target_id)
          end
        end

        false
      end

      # BFS to find all atoms that depend on the given atom (transitive)
      def all_descendants(atom_id, blocking_only: true)
        return Set.new if atom_id.nil?

        traverse_bfs(atom_id) do |current|
          outgoing_bonds(current, blocking_only: blocking_only).map(&:target_id)
        end
      end

      # BFS to find all atoms that the given atom depends on (transitive)
      def all_ancestors(atom_id, blocking_only: true)
        return Set.new if atom_id.nil?

        traverse_bfs(atom_id) do |current|
          incoming_bonds(current, blocking_only: blocking_only).map(&:source_id)
        end
      end

      # Direct bonds where this atom is blocked by others (incoming blocking bonds)
      def direct_blockers(atom_id)
        incoming_bonds(atom_id, blocking_only: true)
      end

      # Direct bonds where this atom blocks others (outgoing blocking bonds)
      def direct_dependents(atom_id)
        outgoing_bonds(atom_id, blocking_only: true)
      end

      private

      attr_reader :indexer

      def traverse_bfs(start_id)
        visited = Set.new
        queue = [start_id]

        while (current = queue.shift)
          next if visited.include?(current)

          visited.add(current)
          neighbors = yield(current)
          queue.concat(neighbors)
        end

        visited.delete(start_id)
        visited
      end

      def outgoing_bonds(atom_id, blocking_only:)
        bonds = indexer.bonds_from(atom_id)
        blocking_only ? bonds.select(&:blocking?) : bonds
      end

      def incoming_bonds(atom_id, blocking_only:)
        bonds = indexer.bonds_to(atom_id)
        blocking_only ? bonds.select(&:blocking?) : bonds
      end
    end
  end
end
