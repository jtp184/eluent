# frozen_string_literal: true

module Eluent
  module Graph
    # Error raised when a cycle is detected in the dependency graph
    class CycleDetectedError < Eluent::Error
      attr_reader :cycle_path

      def initialize(cycle_path)
        @cycle_path = cycle_path
        super("Cycle detected: #{cycle_path.join(' -> ')}")
      end
    end

    # Pre-creation validation for cycle detection
    class CycleDetector
      def initialize(dependency_graph)
        @graph = dependency_graph
      end

      # Validates that creating a bond won't introduce a cycle
      # Returns: { valid: true } or { valid: false, cycle_path: [...] }
      def validate_bond(source_id:, target_id:, dependency_type:)
        return { valid: true } unless blocking_type?(dependency_type)
        return { valid: true } if source_id == target_id # Self-reference handled elsewhere

        # A cycle would be created if target can already reach source
        # Adding source -> target would then create: source -> target -> ... -> source
        if cycle_path = find_path_to_source(source_id: source_id, target_id: target_id)
          { valid: false, cycle_path: cycle_path }
        else
          { valid: true }
        end
      end

      # Validates and raises CycleDetectedError if invalid
      def validate_bond!(source_id:, target_id:, dependency_type:)
        result = validate_bond(source_id: source_id, target_id: target_id, dependency_type: dependency_type)
        raise CycleDetectedError, result[:cycle_path] unless result[:valid]

        result
      end

      private

      attr_reader :graph

      def blocking_type?(dependency_type)
        type = Models::DependencyType[dependency_type]
        type&.blocking?
      end

      # Uses BFS to find if there's a path from target back to source
      # Returns the cycle path if found, nil otherwise
      def find_path_to_source(source_id:, target_id:)
        return nil if source_id.nil? || target_id.nil?

        visited = Set.new
        queue = [[target_id, [source_id, target_id]]]

        while (current, path = queue.shift)
          next if visited.include?(current)

          # Found a path back to source - we have a cycle
          return path if current == source_id && path.length > 2

          visited.add(current)

          graph.direct_dependents(current).each do |bond|
            next_id = bond.target_id
            next if visited.include?(next_id)

            new_path = path + [next_id]
            # Check for cycle completion
            return new_path if next_id == source_id

            queue.push([next_id, new_path])
          end
        end

        nil
      end
    end
  end
end
