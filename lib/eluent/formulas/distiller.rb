# frozen_string_literal: true

module Eluent
  module Formulas
    # Extracts a reusable formula from existing work item hierarchy
    class Distiller
      def initialize(repository:)
        @repository = repository
      end

      # Distills a formula from an existing atom hierarchy.
      #
      # @param root_atom_id [String] ID of the root atom to distill from
      # @param formula_id [String] ID for the new formula
      # @param literal_to_var_map [Hash] Map of literal strings to variable names
      #   e.g., { "v2.0" => "version" } replaces "v2.0" with {{version}}
      def distill(root_atom_id, formula_id:, literal_to_var_map: {})
        root = repository.find_atom(root_atom_id)
        raise Registry::IdNotFoundError, root_atom_id unless root

        children = find_children(root.id)
        raise ParseError, "Cannot distill formula from atom '#{root_atom_id}': no children found" if children.empty?

        graph = build_dependency_graph(root.id, children)

        steps = build_steps_with_unique_ids(children, graph, literal_to_var_map)
        variables = build_variable_definitions(literal_to_var_map)

        Models::Formula.new(
          id: formula_id,
          title: templatize_text(root.title, literal_to_var_map),
          description: templatize_text(root.description, literal_to_var_map),
          version: 1,
          retention: :permanent,
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

      def build_steps_with_unique_ids(children, graph, literal_to_var_map)
        used_ids = {}
        children.map do |child|
          step = build_step(child, graph, literal_to_var_map)
          unique_id = ensure_unique_id(step.id, used_ids)
          used_ids[unique_id] = true

          # Return step with unique ID if needed
          if unique_id == step.id
            step
          else
            Models::Step.new(
              id: unique_id,
              title: step.title,
              issue_type: step.issue_type,
              description: step.description,
              depends_on: step.depends_on,
              assignee: step.assignee,
              priority: step.priority,
              labels: step.labels
            )
          end
        end
      end

      def ensure_unique_id(base_id, used_ids)
        return base_id unless used_ids.key?(base_id)

        counter = 2
        counter += 1 while used_ids.key?("#{base_id}-#{counter}")
        "#{base_id}-#{counter}"
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

      def build_step(atom, graph, literal_to_var_map)
        step_id = generate_step_id(atom)
        dependencies = graph[atom.id].map { |dep_id| id_to_step_id(dep_id) }.compact

        Models::Step.new(
          id: step_id,
          title: templatize_text(atom.title, literal_to_var_map),
          issue_type: atom.issue_type,
          description: templatize_text(atom.description, literal_to_var_map),
          depends_on: dependencies,
          assignee: templatize_text(atom.assignee, literal_to_var_map),
          priority: atom.priority,
          labels: atom.labels.to_a.map { |l| templatize_text(l, literal_to_var_map) }
        )
      end

      def generate_step_id(atom)
        # Use existing formula_step_id if available, otherwise generate from title
        atom.metadata&.dig('formula_step_id') || slugify(atom.title)
      end

      def id_to_step_id(atom_id)
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

      # Replaces literal strings with variable template placeholders ({{varname}}).
      def templatize_text(text, literal_to_var_map)
        return text unless text.is_a?(String)

        result = text.dup
        # Sort by key length descending to avoid overlapping replacements
        # (e.g., "Authentication" before "Auth")
        sorted_mappings = literal_to_var_map.sort_by { |literal_value, _| -literal_value.to_s.length }
        sorted_mappings.each do |literal_value, var_name|
          result = result.gsub(literal_value.to_s, "{{#{var_name}}}")
        end
        result
      end

      # Builds variable definitions from the extraction mappings.
      def build_variable_definitions(literal_to_var_map)
        literal_to_var_map.to_h do |literal_value, var_name|
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
