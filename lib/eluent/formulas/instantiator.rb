# frozen_string_literal: true

module Eluent
  module Formulas
    # Creates atoms from formula template with variable substitution
    class Instantiator
      def initialize(repository:)
        @repository = repository
      end

      def instantiate(formula, variables: {}, parent_id: nil)
        resolver = VariableResolver.new(formula)
        resolved_values = resolver.resolve(variables)
        resolved_formula = resolver.substitute_formula(resolved_values)

        result = InstantiationResult.new(formula: formula, resolved_values: resolved_values)

        if parent_id
          # Attach to existing atom
          result.root_atom = repository.find_atom(parent_id)
          raise Registry::IdNotFoundError, parent_id unless result.root_atom

          create_step_atoms(resolved_formula, result, parent_id: parent_id)
        else
          # Create new root epic
          result.root_atom = create_root_atom(resolved_formula)
          create_step_atoms(resolved_formula, result, parent_id: result.root_atom.id)
        end

        create_dependency_bonds(resolved_formula, result)
        result
      end

      private

      attr_reader :repository

      def create_root_atom(formula)
        repository.create_atom(
          title: formula.title,
          description: formula.description,
          issue_type: :epic,
          metadata: {
            formula_id: formula.id,
            formula_version: formula.version,
            instantiated_at: Time.now.utc.iso8601
          },
          ephemeral: formula.ephemeral?
        )
      end

      def create_step_atoms(formula, result, parent_id:)
        formula.steps.each do |step|
          atom = repository.create_atom(
            title: step.title,
            description: step.description,
            issue_type: step.issue_type,
            assignee: step.assignee,
            priority: step.priority || 2,
            labels: step.labels,
            parent_id: parent_id,
            metadata: {
              formula_id: formula.id,
              formula_step_id: step.id
            },
            ephemeral: formula.ephemeral?
          )
          result.add_step_atom(step.id, atom)
        end
      end

      def create_dependency_bonds(formula, result)
        formula.steps.each do |step|
          next unless step.dependencies?

          target_atom = result.atom_for_step(step.id)

          step.depends_on.each do |dep_step_id|
            source_atom = result.atom_for_step(dep_step_id)
            next unless source_atom && target_atom

            bond = repository.create_bond(
              source_id: source_atom.id,
              target_id: target_atom.id,
              dependency_type: :blocks
            )
            result.add_bond(bond)
          end
        end
      end
    end

    # Result of instantiating a formula
    class InstantiationResult
      attr_accessor :root_atom
      attr_reader :formula, :resolved_values, :step_atoms, :bonds

      def initialize(formula:, resolved_values:)
        @formula = formula
        @resolved_values = resolved_values
        @step_atoms = {}
        @bonds = []
        @root_atom = nil
      end

      def add_step_atom(step_id, atom)
        step_atoms[step_id] = atom
      end

      def add_bond(bond)
        bonds << bond
      end

      def atom_for_step(step_id)
        step_atoms[step_id]
      end

      def all_atoms
        [root_atom, *step_atoms.values].compact
      end

      def to_h
        {
          formula_id: formula.id,
          root_atom_id: root_atom&.id,
          step_atoms: step_atoms.transform_values(&:id),
          bonds_count: bonds.size,
          resolved_values: resolved_values
        }
      end
    end
  end
end
