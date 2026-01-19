# frozen_string_literal: true

module Eluent
  module Models
    # Reusable template for creating work item hierarchies
    class Formula
      include Validations

      attr_accessor :id, :title, :description, :version, :phase,
                    :variables, :steps, :created_at, :updated_at, :metadata

      VALID_PHASES = %i[persistent ephemeral].freeze

      def initialize(
        id:,
        title:,
        description: nil,
        version: 1,
        phase: :persistent,
        variables: {},
        steps: [],
        created_at: Time.now.utc,
        updated_at: Time.now.utc,
        metadata: {}
      )
        @id = validate_id(id)
        @title = validate_title(title)
        @description = validate_content(description)
        @version = validate_version(version)
        @phase = validate_phase(phase)
        @variables = build_variables(variables)
        @steps = build_steps(steps)
        @created_at = parse_time(created_at)
        @updated_at = parse_time(updated_at)
        @metadata = metadata
      end

      def persistent?
        phase == :persistent
      end

      def ephemeral?
        phase == :ephemeral
      end

      def variable_names
        variables.keys
      end

      def required_variables
        variables.select { |_, v| v.required? }
      end

      def optional_variables
        variables.reject { |_, v| v.required? }
      end

      def step_by_id(step_id)
        steps.find { |s| s.id == step_id.to_s }
      end

      def to_h
        {
          _type: 'formula',
          id: id,
          title: title,
          description: description,
          version: version,
          phase: phase.to_s,
          variables: variables.transform_values(&:to_h),
          steps: steps.map(&:to_h),
          created_at: created_at&.iso8601,
          updated_at: updated_at&.iso8601,
          metadata: metadata
        }
      end

      def ==(other)
        other.is_a?(Formula) && id == other.id
      end

      def eql?(other)
        self == other
      end

      def hash
        id.hash
      end

      private

      def validate_id(value)
        id_str = value.to_s.strip
        raise ValidationError, 'formula id cannot be blank' if id_str.empty?
        raise ValidationError, 'formula id must match [a-z0-9-]+' unless id_str.match?(/\A[a-z0-9-]+\z/)

        id_str
      end

      def validate_version(value)
        Integer(value).tap do |v|
          raise ValidationError, 'version must be positive' unless v.positive?
        end
      rescue ArgumentError
        raise ValidationError, "version must be integer, got: #{value}"
      end

      def validate_phase(value)
        phase_sym = value.to_sym
        return phase_sym if VALID_PHASES.include?(phase_sym)

        raise ValidationError, "invalid phase: #{value}. Valid: #{VALID_PHASES.join(', ')}"
      end

      def build_variables(variables_hash)
        variables_hash.to_h do |name, attrs|
          attrs = attrs.is_a?(Variable) ? attrs.to_h : (attrs || {})
          [name.to_s, Variable.new(name: name.to_s, **attrs.transform_keys(&:to_sym))]
        end
      end

      def build_steps(steps_array)
        Array(steps_array).map.with_index do |step_data, idx|
          if step_data.is_a?(Step)
            step_data
          else
            step_attrs = step_data.transform_keys(&:to_sym)
            step_attrs[:id] ||= "step-#{idx + 1}"
            Step.new(**step_attrs)
          end
        end
      end
    end

    # Variable definition within a formula
    class Variable
      attr_accessor :name, :description, :required, :default, :enum, :pattern

      def initialize(
        name:,
        description: nil,
        required: false,
        default: nil,
        enum: nil,
        pattern: nil
      )
        @name = name.to_s
        @description = description
        @required = required
        @default = default
        @enum = enum&.map(&:to_s)
        @pattern = pattern ? build_pattern(pattern) : nil
      end

      private def build_pattern(pattern)
        Regexp.new(pattern)
      rescue RegexpError => e
        raise ValidationError, "invalid pattern for variable '#{@name}': #{e.message}"
      end

      # A variable is only truly required if marked required AND has no default.
      # Variables with defaults are effectively optional since the default fills in.
      def required?
        !!required && default.nil?
      end

      def optional?
        !required?
      end

      def default?
        !default.nil?
      end

      def enum?
        enum&.any?
      end

      def pattern?
        !pattern.nil?
      end

      def validate_value(value)
        errors = []

        if value.nil?
          errors << "#{name} is required" if required?
          return errors
        end

        value_str = value.to_s

        errors << "#{name} must be one of: #{enum.join(', ')}" if enum? && !enum.include?(value_str)

        errors << "#{name} must match pattern: #{pattern.source}" if pattern? && !value_str.match?(pattern)

        errors
      end

      def to_h
        hash = {}
        hash[:description] = description if description
        hash[:required] = true if required
        hash[:default] = default if default?
        hash[:enum] = enum if enum?
        hash[:pattern] = pattern.source if pattern?
        hash
      end

      def ==(other)
        other.is_a?(Variable) && name == other.name
      end

      def eql?(other)
        self == other
      end

      def hash
        name.hash
      end
    end

    # Step within a formula defining an atom to create
    class Step
      include Validations

      attr_accessor :id, :title, :issue_type, :description, :depends_on,
                    :assignee, :priority, :labels

      def initialize(
        id:,
        title:,
        issue_type: :task,
        description: nil,
        depends_on: [],
        assignee: nil,
        priority: nil,
        labels: []
      )
        @id = id.to_s
        @title = validate_title(title)
        @issue_type = validate_issue_type(issue_type)
        @description = validate_content(description)
        @depends_on = Array(depends_on).map(&:to_s)
        @assignee = assignee
        @priority = priority ? validate_priority(priority) : nil
        @labels = Array(labels)
      end

      def dependencies?
        depends_on.any?
      end

      def to_h
        hash = { id: id, title: title }
        hash[:issue_type] = issue_type.to_s unless issue_type.to_s == 'task'
        hash[:description] = description if description
        hash[:depends_on] = depends_on if dependencies?
        hash[:assignee] = assignee if assignee
        hash[:priority] = priority if priority
        hash[:labels] = labels if labels.any?
        hash
      end

      def ==(other)
        other.is_a?(Step) && id == other.id
      end

      def eql?(other)
        self == other
      end

      def hash
        id.hash
      end
    end
  end
end
