# frozen_string_literal: true

module Eluent
  module Formulas
    # Extracts a reusable formula from existing work item hierarchy
    class Distiller
      def initialize(repository:)
        @repository = repository
      end

      def distill(root_atom_id, formula_id:, variable_mappings: {})
        root = repository.find_atom(root_atom_id)
        raise Registry::IdNotFoundError, root_atom_id unless root

        children = find_children(root.id)
        graph = build_dependency_graph(root.id, children)

        steps = children.map { |child| build_step(child, graph, variable_mappings) }
        variables = extract_variables(variable_mappings)

        Models::Formula.new(
          id: formula_id,
          title: apply_reverse_mappings(root.title, variable_mappings),
          description: apply_reverse_mappings(root.description, variable_mappings),
          version: 1,
          phase: :persistent,
          variables: variables,
          steps: steps,
          metadata: {
            distilled_from: root.id,
            distilled_at: Time.now.utc.iso8601
          }
        )
      end

      private

      attr_reader :repository

      def find_children(parent_id)
        repository.indexer.children_of(parent_id)
      end

      def build_dependency_graph(root_id, children)
        child_ids = Set.new([root_id] + children.map(&:id))
        graph = Hash.new { |h, k| h[k] = [] }

        children.each do |child|
          bonds = repository.bonds_for(child.id)
          bonds[:incoming].each do |bond|
            next unless child_ids.include?(bond.source_id)
            next unless bond.dependency_type.blocking?

            graph[child.id] << bond.source_id
          end
        end

        graph
      end

      def build_step(atom, graph, variable_mappings)
        step_id = generate_step_id(atom)
        dependencies = graph[atom.id].map { |dep_id| id_to_step_id(dep_id, graph) }.compact

        Models::Step.new(
          id: step_id,
          title: apply_reverse_mappings(atom.title, variable_mappings),
          issue_type: atom.issue_type,
          description: apply_reverse_mappings(atom.description, variable_mappings),
          depends_on: dependencies,
          assignee: apply_reverse_mappings(atom.assignee, variable_mappings),
          priority: atom.priority,
          labels: atom.labels.to_a.map { |l| apply_reverse_mappings(l, variable_mappings) }
        )
      end

      def generate_step_id(atom)
        # Use existing formula_step_id if available, otherwise generate from title
        atom.metadata&.dig('formula_step_id') || slugify(atom.title)
      end

      def id_to_step_id(atom_id, _graph)
        atom = repository.find_atom_by_id(atom_id)
        return nil unless atom

        generate_step_id(atom)
      end

      def slugify(text)
        return 'step' unless text

        text.downcase
            .gsub(/[^a-z0-9\s-]/, '')
            .gsub(/\s+/, '-')
            .gsub(/-+/, '-')
            .slice(0, 30)
            .gsub(/^-|-$/, '')
            .then { |s| s.empty? ? 'step' : s }
      end

      def apply_reverse_mappings(text, mappings)
        return text unless text.is_a?(String)

        result = text.dup
        # Sort by key length descending to avoid overlapping replacements
        # (e.g., "Authentication" before "Auth")
        sorted_mappings = mappings.sort_by { |literal_value, _| -literal_value.to_s.length }
        sorted_mappings.each do |literal_value, var_name|
          result = result.gsub(literal_value.to_s, "{{#{var_name}}}")
        end
        result
      end

      def extract_variables(mappings)
        mappings.to_h do |literal_value, var_name|
          var_attrs = {
            description: "Extracted from '#{literal_value}'",
            required: true
          }
          [var_name.to_s, var_attrs]
        end
      end
    end
  end
end
