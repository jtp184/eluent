# frozen_string_literal: true

module Eluent
  module Formulas
    # Raised when variable validation or resolution fails
    class VariableError < Error
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super("Variable errors: #{@errors.join('; ')}")
      end
    end

    # Handles {{var}} substitution and validation in formula templates
    class VariableResolver
      VARIABLE_PATTERN = /\{\{(\w+)\}\}/

      def initialize(formula)
        @formula = formula
        @variables = formula.variables
      end

      def resolve(provided_values = {})
        provided = normalize_keys(provided_values)
        resolved = apply_defaults(provided)

        validate!(resolved)
        resolved
      end

      def substitute(text, resolved_values)
        return text unless text.is_a?(String)

        text.gsub(VARIABLE_PATTERN) do |match|
          var_name = ::Regexp.last_match(1)
          resolved_values.fetch(var_name, match)
        end
      end

      def substitute_step(step, resolved_values)
        Models::Step.new(
          id: step.id,
          title: substitute(step.title, resolved_values),
          issue_type: step.issue_type,
          description: substitute(step.description, resolved_values),
          depends_on: step.depends_on,
          assignee: substitute(step.assignee, resolved_values),
          priority: step.priority,
          labels: step.labels.map { |l| substitute(l, resolved_values) }
        )
      end

      def substitute_formula(resolved_values)
        Models::Formula.new(
          id: formula.id,
          title: substitute(formula.title, resolved_values),
          description: substitute(formula.description, resolved_values),
          version: formula.version,
          retention: formula.retention,
          variables: formula.variables,
          steps: formula.steps.map { |s| substitute_step(s, resolved_values) },
          created_at: formula.created_at,
          updated_at: formula.updated_at,
          metadata: formula.metadata
        )
      end

      def validate!(resolved_values)
        errors = collect_errors(resolved_values)
        raise VariableError, errors if errors.any?

        true
      end

      def missing_required
        variables.select { |_, v| v.required? }.keys
      end

      def extract_variables(text)
        return [] unless text.is_a?(String)

        text.scan(VARIABLE_PATTERN).flatten.uniq
      end

      def all_referenced_variables
        all_text_fields.flat_map { |text| extract_variables(text) }.uniq
      end

      private

      attr_reader :formula, :variables

      def normalize_keys(hash)
        hash.transform_keys(&:to_s)
      end

      def apply_defaults(provided)
        variables.each_with_object(provided.dup) do |(name, var), result|
          result[name] = var.default if var.default? && !result.key?(name)
        end
      end

      def collect_errors(resolved_values)
        errors = []

        # Check for missing required variables
        variables.each do |name, var|
          value = resolved_values[name]
          errors.concat(var.validate_value(value))
        end

        # Check for unknown variables in provided values
        unknown = resolved_values.keys - variables.keys
        unknown.each do |name|
          errors << "Unknown variable: #{name}"
        end

        # Check for undefined variables referenced in templates
        referenced = all_referenced_variables
        undefined = referenced - variables.keys
        undefined.each do |name|
          errors << "Variable '#{name}' is referenced but not defined"
        end

        errors
      end

      def all_text_fields
        fields = [formula.title, formula.description]
        formula.steps.each do |step|
          fields << step.title
          fields << step.description
          fields << step.assignee
          fields.concat(step.labels)
        end
        fields.compact
      end
    end
  end
end
