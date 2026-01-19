# frozen_string_literal: true

module Eluent
  module Formulas
    # Combines multiple formulas into a single composite formula
    class Composer
      COMPOSITION_TYPES = %i[sequential parallel conditional].freeze

      def initialize(parser:)
        @parser = parser
      end

      def compose(formula_ids, new_id:, type: :sequential, title: nil)
        formulas = formula_ids.map { |id| parser.parse(id) }
        validate_composition(formulas, type)

        case type
        when :sequential then compose_sequential(formulas, new_id, title)
        when :parallel then compose_parallel(formulas, new_id, title)
        when :conditional then compose_conditional(formulas, new_id, title)
        else raise ParseError, "Unknown composition type: #{type}"
        end
      end

      private

      attr_reader :parser

      def validate_composition(formulas, type)
        raise ParseError, 'At least two formulas required for composition' if formulas.size < 2
        raise ParseError, "Invalid composition type: #{type}" unless COMPOSITION_TYPES.include?(type.to_sym)

        # Check for variable name conflicts
        all_vars = formulas.flat_map { |f| f.variables.keys }
        duplicates = all_vars.select { |v| all_vars.count(v) > 1 }.uniq
        return if duplicates.empty?

        warn "el: warning: overlapping variables will be merged: #{duplicates.join(', ')}"
      end

      def compose_sequential(formulas, new_id, title)
        merged_steps = []
        merged_variables = {}
        prev_last_step_id = nil

        formulas.each do |formula|
          prefix = "#{formula.id}-"
          merged_variables.merge!(prefix_variables(formula.variables, prefix))
          merged_steps.concat(sequential_steps(formula, prefix, prev_last_step_id))
          prev_last_step_id = "#{prefix}#{formula.steps.last.id}" if formula.steps.any?
        end

        build_composed_formula(
          new_id, formulas, merged_variables, merged_steps,
          title: title, type: 'sequential', joiner: ' → '
        )
      end

      def sequential_steps(formula, prefix, prev_last_step_id)
        formula.steps.each_with_index.map do |step, step_idx|
          new_step = prefix_step(step, prefix)
          should_chain = prev_last_step_id && step_idx.zero? && step.depends_on.empty?
          should_chain ? step_with_dependency(new_step, prev_last_step_id) : new_step
        end
      end

      def step_with_dependency(step, dep_id)
        Models::Step.new(
          id: step.id, title: step.title, issue_type: step.issue_type,
          description: step.description, depends_on: [dep_id], assignee: step.assignee,
          priority: step.priority, labels: step.labels
        )
      end

      def compose_parallel(formulas, new_id, title)
        merged_steps, merged_variables = collect_prefixed_steps_and_vars(formulas)
        build_composed_formula(
          new_id, formulas, merged_variables, merged_steps,
          title: title, type: 'parallel', joiner: ' + '
        )
      end

      def compose_conditional(formulas, new_id, title)
        merged_steps, merged_variables = collect_conditional_steps_and_vars(formulas)
        build_composed_formula(
          new_id, formulas, merged_variables, merged_steps,
          title: title, type: 'conditional', joiner: ' | ',
          description_suffix: ". Use 'branch' variable to select."
        )
      end

      def collect_prefixed_steps_and_vars(formulas)
        steps = []
        variables = {}
        formulas.each do |formula|
          prefix = "#{formula.id}-"
          variables.merge!(prefix_variables(formula.variables, prefix))
          formula.steps.each { |step| steps << prefix_step(step, prefix) }
        end
        [steps, variables]
      end

      def collect_conditional_steps_and_vars(formulas)
        steps = []
        variables = { 'branch' => branch_variable(formulas) }
        formulas.each do |formula|
          prefix = "#{formula.id}-"
          variables.merge!(prefix_variables(formula.variables, prefix))
          formula.steps.each { |step| steps << conditional_step(step, prefix, formula.id) }
        end
        [steps, variables]
      end

      def branch_variable(formulas)
        { description: 'Select which formula branch to execute', required: true, enum: formulas.map(&:id) }
      end

      def conditional_step(step, prefix, formula_id)
        prefixed = prefix_step(step, prefix)
        step_with_condition(prefixed, formula_id)
      end

      def step_with_condition(step, formula_id)
        Models::Step.new(
          id: step.id, title: step.title, issue_type: step.issue_type,
          description: step.description, depends_on: step.depends_on, assignee: step.assignee,
          priority: step.priority, labels: step.labels + ["condition:branch=#{formula_id}"]
        )
      end

      def build_composed_formula(new_id, formulas, variables, steps, title:, type:, joiner:, description_suffix: '')
        type_label = type.capitalize
        Models::Formula.new(
          id: new_id,
          title: title || "#{type_label}: #{formulas.map(&:title).join(joiner)}",
          description: "#{type_label} composition of: #{formulas.map(&:id).join(', ')}#{description_suffix}",
          version: 1, phase: :persistent, variables: variables, steps: steps,
          metadata: { composition_type: type, source_formulas: formulas.map(&:id) }
        )
      end

      def prefix_variables(variables, prefix)
        variables.to_h do |name, var|
          prefixed_name = "#{prefix}#{name}"
          attrs = var.to_h.merge(description: "[#{prefix[0..-2]}] #{var.description || name}")
          [prefixed_name, attrs]
        end
      end

      def prefix_step(step, prefix)
        Models::Step.new(
          id: "#{prefix}#{step.id}",
          title: prefix_variable_refs(step.title, prefix),
          issue_type: step.issue_type,
          description: prefix_variable_refs(step.description, prefix),
          depends_on: step.depends_on.map { |d| "#{prefix}#{d}" },
          assignee: prefix_variable_refs(step.assignee, prefix),
          priority: step.priority,
          labels: step.labels.map { |l| prefix_variable_refs(l, prefix) }
        )
      end

      def prefix_variable_refs(text, prefix)
        return text unless text.is_a?(String)

        text.gsub(/\{\{(\w+)\}\}/) { "{{#{prefix}#{::Regexp.last_match(1)}}}" }
      end
    end
  end
end
