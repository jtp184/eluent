# frozen_string_literal: true

require 'yaml'

module Eluent
  module Formulas
    # Raised when a formula file cannot be found
    class FormulaNotFoundError < Error
      attr_reader :formula_id

      def initialize(formula_id)
        @formula_id = formula_id
        super("Formula not found: #{formula_id}")
      end
    end

    # Raised when formula parsing fails due to invalid YAML or structure
    class ParseError < Error
      attr_reader :formula_id, :details

      def initialize(message, formula_id: nil, details: nil)
        @formula_id = formula_id
        @details = details
        super(message)
      end
    end

    # Parses YAML formula files into Formula model objects
    class Parser
      def initialize(paths:)
        @paths = paths
      end

      def parse(formula_id)
        file_path = formula_file_path(formula_id)
        raise FormulaNotFoundError, formula_id unless File.exist?(file_path)

        yaml = load_yaml(file_path, formula_id)
        build_formula(yaml, formula_id)
      end

      def parse_file(file_path)
        raise FormulaNotFoundError, file_path unless File.exist?(file_path)

        yaml = load_yaml(file_path, File.basename(file_path, '.yaml'))
        build_formula(yaml, yaml['id'])
      end

      def list
        return [] unless Dir.exist?(formulas_dir)

        formulas = Dir.glob(File.join(formulas_dir, '*.yaml')).map do |file_path|
          yaml = load_yaml(file_path, File.basename(file_path, '.yaml'))
          {
            id: yaml['id'],
            title: yaml['title'],
            version: yaml['version'] || 1,
            retention: yaml['retention'] || 'permanent',
            steps_count: Array(yaml['steps']).size,
            variables_count: (yaml['variables'] || {}).size
          }
        end
        formulas.sort_by { |f| f[:id] }
      end

      def exists?(formula_id)
        File.exist?(formula_file_path(formula_id))
      end

      def save(formula)
        ensure_formulas_dir_exists
        File.write(formula_file_path(formula.id), to_yaml(formula))
        formula
      end

      private

      attr_reader :paths

      def formulas_dir
        paths.formulas_dir
      end

      def formula_file_path(formula_id)
        File.join(formulas_dir, "#{formula_id}.yaml")
      end

      def ensure_formulas_dir_exists
        FileUtils.mkdir_p(formulas_dir)
      end

      def load_yaml(file_path, formula_id)
        content = File.read(file_path)
        YAML.safe_load(content, permitted_classes: [Symbol, Date, Time])
      rescue Psych::SyntaxError => e
        raise ParseError.new("Invalid YAML syntax: #{e.message}", formula_id: formula_id, details: { line: e.line })
      rescue Errno::ENOENT
        raise FormulaNotFoundError, formula_id
      end

      def build_formula(yaml, formula_id)
        validate_yaml_structure(yaml, formula_id)

        Models::Formula.new(
          id: yaml['id'] || formula_id,
          title: yaml['title'],
          description: yaml['description'],
          version: yaml['version'] || 1,
          retention: (yaml['retention'] || 'permanent').to_sym,
          variables: parse_variables(yaml['variables'] || {}),
          steps: parse_steps(yaml['steps'] || []),
          metadata: yaml['metadata'] || {}
        )
      rescue Models::ValidationError => e
        raise ParseError.new("Validation error: #{e.message}", formula_id: formula_id)
      end

      def validate_yaml_structure(yaml, formula_id)
        raise ParseError.new('Formula must have a title', formula_id: formula_id) unless yaml['title']

        if Array(yaml['steps']).empty?
          raise ParseError.new('Formula must have at least one step',
                               formula_id: formula_id)
        end

        validate_step_ids(yaml['steps'], formula_id)
        validate_step_dependencies(yaml['steps'], formula_id)
      end

      def validate_step_ids(steps, formula_id)
        ids = steps.map { |s| s['id'] }.compact
        duplicates = ids.select { |id| ids.count(id) > 1 }.uniq
        return if duplicates.empty?

        raise ParseError.new("Duplicate step IDs: #{duplicates.join(', ')}", formula_id: formula_id)
      end

      def validate_step_dependencies(steps, formula_id)
        step_ids = steps.map.with_index { |s, i| s['id'] || "step-#{i + 1}" }
        dependency_graph = build_step_dependency_graph(steps, step_ids)

        steps.each_with_index do |step, idx|
          step_id = step['id'] || "step-#{idx + 1}"
          Array(step['depends_on']).each do |dep_id|
            validate_dependency_exists(step_id, dep_id, step_ids, formula_id)
            validate_no_self_dependency(step_id, dep_id, formula_id)
          end
        end

        validate_no_cycles(dependency_graph, step_ids, formula_id)
      end

      def build_step_dependency_graph(steps, step_ids)
        steps.each_with_index.to_h do |step, idx|
          step_id = step['id'] || "step-#{idx + 1}"
          deps = Array(step['depends_on']).select { |d| step_ids.include?(d) }
          [step_id, deps]
        end
      end

      def validate_dependency_exists(step_id, dep_id, step_ids, formula_id)
        return if step_ids.include?(dep_id)

        raise ParseError.new(
          "Step '#{step_id}' depends on unknown step '#{dep_id}'",
          formula_id: formula_id
        )
      end

      def validate_no_self_dependency(step_id, dep_id, formula_id)
        return unless step_id == dep_id

        raise ParseError.new(
          "Step '#{step_id}' cannot depend on itself",
          formula_id: formula_id
        )
      end

      def validate_no_cycles(graph, step_ids, formula_id)
        visited = {}
        rec_stack = {}

        step_ids.each do |step_id|
          cycle = detect_cycle(step_id, graph, visited, rec_stack, [])
          next unless cycle

          raise ParseError.new(
            "Circular dependency detected: #{cycle.join(' -> ')}",
            formula_id: formula_id
          )
        end
      end

      def detect_cycle(node, graph, visited, rec_stack, path)
        return nil if visited[node]

        visited[node] = true
        rec_stack[node] = true
        current_path = path + [node]

        graph[node]&.each do |dep|
          return current_path + [dep] if rec_stack[dep]

          cycle = detect_cycle(dep, graph, visited, rec_stack, current_path)
          return cycle if cycle
        end

        rec_stack[node] = false
        nil
      end

      def parse_variables(variables_hash)
        variables_hash.to_h do |name, attrs|
          name_str = name.to_s
          raise ParseError, 'Variable name cannot be blank' if name_str.strip.empty?

          attrs ||= {}
          [name_str, attrs.transform_keys(&:to_sym)]
        end
      end

      def parse_steps(steps_array)
        steps_array.map.with_index do |step, idx|
          step_hash = step.transform_keys(&:to_sym)
          step_hash[:id] ||= "step-#{idx + 1}"
          step_hash
        end
      end

      def to_yaml(formula)
        yaml = build_yaml_base(formula)
        yaml['variables'] = serialize_variables(formula.variables) if formula.variables.any?
        yaml['steps'] = formula.steps.map { |step| serialize_step(step) }
        yaml['metadata'] = formula.metadata if formula.metadata&.any?
        YAML.dump(yaml)
      end

      def build_yaml_base(formula)
        yaml = { 'id' => formula.id, 'title' => formula.title }
        yaml['description'] = formula.description if formula.description
        yaml['version'] = formula.version if formula.version != 1
        yaml['retention'] = formula.retention.to_s if formula.retention != :permanent
        yaml
      end

      def serialize_variables(variables)
        variables.transform_values do |var|
          var_hash = {}
          var_hash['description'] = var.description if var.description
          var_hash['required'] = true if var.required
          var_hash['default'] = var.default if var.default?
          var_hash['enum'] = var.enum if var.enum?
          var_hash['pattern'] = var.pattern.source if var.pattern?
          var_hash.empty? ? nil : var_hash
        end.compact
      end

      def serialize_step(step)
        step_hash = { 'id' => step.id, 'title' => step.title }
        step_hash['issue_type'] = step.issue_type.to_s unless step.issue_type.to_s == 'task'
        step_hash['description'] = step.description if step.description
        step_hash['depends_on'] = step.depends_on if step.dependencies?
        step_hash['assignee'] = step.assignee if step.assignee
        step_hash['priority'] = step.priority if step.priority
        step_hash['labels'] = step.labels if step.labels.any?
        step_hash
      end
    end
  end
end
