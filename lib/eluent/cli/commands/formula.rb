# frozen_string_literal: true

require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Formula management commands for reusable work templates
      class Formula < BaseCommand
        include Formatting

        ACTIONS = %w[list show instantiate distill compose attach].freeze

        usage do
          program 'el formula'
          desc 'Manage formulas (reusable work templates)'
          example 'el formula list', 'List all formulas'
          example 'el formula show ID', 'Show formula details'
          example 'el formula instantiate ID --var name=value', 'Create items from template'
          example 'el formula distill ROOT_ID --id new-formula --extract "v2.0=version"', 'Extract formula from work'
          example 'el formula compose A B --type sequential --id combined', 'Combine formulas'
          example 'el formula attach ID TARGET --type parallel', 'Attach formula to existing item'
        end

        argument :action do
          required
          desc 'Action: list, show, instantiate, distill, compose, attach'
        end

        argument :target do
          optional
          desc 'Formula ID or atom ID'
        end

        argument :extra_args do
          optional
          arity zero_or_more
          desc 'Additional arguments (e.g., formula IDs for compose)'
        end

        option :var do
          short '-V'
          long '--var VAR'
          desc 'Variable value in name=value format (can be repeated)'
          arity zero_or_more
        end

        option :extract do
          short '-E'
          long '--extract MAPPING'
          desc 'Extract literal as variable: "literal=varname" (can be repeated, for distill)'
          arity zero_or_more
        end

        option :id do
          long '--id ID'
          desc 'ID for new formula (distill/compose)'
        end

        option :title do
          short '-t'
          long '--title TITLE'
          desc 'Title for new formula'
        end

        option :type do
          long '--type TYPE'
          desc 'Composition type (sequential, parallel, conditional) or attachment type'
          default 'sequential'
        end

        flag :help do
          short '-h'
          long '--help'
          desc 'Print usage'
        end

        def run
          if params[:help]
            puts help
            return 0
          end

          action = params[:action]

          unless ACTIONS.include?(action)
            return error('INVALID_ACTION', "Unknown action: #{action}. Must be one of: #{ACTIONS.join(', ')}")
          end

          ensure_initialized!

          send("action_#{action}")
        end

        private

        def parser
          @parser ||= Formulas::Parser.new(paths: repository.paths)
        end

        def action_list
          formulas = parser.list

          if @robot_mode
            output_list_json(formulas)
          else
            output_list_formatted(formulas)
          end

          0
        end

        def action_show
          formula_id = params[:target]
          return error('MISSING_ID', 'Formula ID required: el formula show ID') unless formula_id

          formula = parser.parse(formula_id)

          if @robot_mode
            output_show_json(formula)
          else
            output_show_formatted(formula)
          end

          0
        end

        def action_instantiate
          formula_id = params[:target]
          return error('MISSING_ID', 'Formula ID required: el formula instantiate ID') unless formula_id

          formula = parser.parse(formula_id)
          variables = parse_variables

          instantiator = Formulas::Instantiator.new(repository: repository)
          result = instantiator.instantiate(formula, variables: variables)

          success("Created #{result.all_atoms.size} items from formula '#{formula_id}'",
                  data: result.to_h)
        end

        def action_distill
          root_id = params[:target]
          return error('MISSING_ID', 'Root atom ID required: el formula distill ROOT_ID') unless root_id

          new_id = params[:id]
          return error('MISSING_ID', 'New formula ID required: el formula distill ROOT_ID --id NEW_ID') unless new_id

          extraction_mappings = parse_extraction_mappings

          distiller = Formulas::Distiller.new(repository: repository)
          formula = distiller.distill(root_id, formula_id: new_id, literal_to_var_map: extraction_mappings)

          parser.save(formula)

          success("Extracted formula '#{new_id}' with #{formula.steps.size} steps",
                  data: formula.to_h)
        end

        def action_compose
          formula_ids = [params[:target], *params[:extra_args]].compact
          return error('MISSING_ARGS', 'At least two formula IDs required') if formula_ids.size < 2

          new_id = params[:id]
          return error('MISSING_ID', 'New formula ID required: --id NEW_ID') unless new_id

          composition_type = params[:type].to_sym
          title = params[:title]

          composer = Formulas::Composer.new(parser: parser)
          formula = composer.compose(formula_ids, new_id: new_id, type: composition_type, title: title)

          parser.save(formula)

          success("Created composite formula '#{new_id}' from #{formula_ids.size} formulas",
                  data: formula.to_h)
        end

        def action_attach
          formula_id = params[:target]
          return error('MISSING_ID', 'Formula ID required') unless formula_id

          target_id = Array(params[:extra_args]).first
          return error('MISSING_ID', 'Target atom ID required: el formula attach FORMULA_ID TARGET_ID') unless target_id

          formula = parser.parse(formula_id)
          variables = parse_variables

          instantiator = Formulas::Instantiator.new(repository: repository)
          result = instantiator.instantiate(formula, variables: variables, parent_id: target_id)

          success("Attached #{result.step_atoms.size} items from formula '#{formula_id}' to #{short_id(target_id)}",
                  data: result.to_h)
        end

        # --- Output Helpers ---

        def output_list_json(formulas)
          puts JSON.generate({
                               status: 'ok',
                               data: { formulas: formulas }
                             })
        end

        def output_list_formatted(formulas)
          if formulas.empty?
            puts @pastel.dim('No formulas found in .eluent/formulas/')
            return
          end

          puts @pastel.bold("Formulas (#{formulas.size}):\n")

          formulas.each do |f|
            retention_badge = f[:retention] == 'ephemeral' ? @pastel.yellow(' [ephemeral]') : ''
            puts "  #{@pastel.cyan(f[:id])}#{retention_badge}"
            puts "    #{f[:title]}"
            puts "    #{f[:steps_count]} steps, #{f[:variables_count]} variables, v#{f[:version]}"
            puts
          end
        end

        def output_show_json(formula)
          puts JSON.generate({
                               status: 'ok',
                               data: formula.to_h
                             })
        end

        def output_show_formatted(formula)
          output_formula_header(formula)
          output_formula_variables(formula.variables) if formula.variables.any?
          output_formula_steps(formula.steps)
        end

        def output_formula_header(formula)
          puts @pastel.bold("Formula: #{formula.id}")
          puts "Title: #{formula.title}"
          puts "Version: #{formula.version}"
          puts "Retention: #{formula.retention}"
          puts "Description: #{formula.description}" if formula.description
          puts
        end

        def output_formula_variables(variables)
          puts @pastel.yellow('Variables:')
          variables.each do |name, var|
            req = var.required? ? @pastel.red('*') : ''
            default_str = var.default? ? " (default: #{var.default})" : ''
            enum_str = var.enum? ? " [#{var.enum.join('|')}]" : ''
            puts "  #{req}#{name}#{default_str}#{enum_str}"
            puts "    #{var.description}" if var.description
          end
          puts
        end

        def output_formula_steps(steps)
          puts @pastel.yellow("Steps (#{steps.size}):")
          steps.each_with_index do |step, idx|
            deps = step.dependencies? ? " <- #{step.depends_on.join(', ')}" : ''
            puts "  #{idx + 1}. [#{step.id}] #{step.title}#{deps}"
            puts "     Type: #{step.issue_type}" unless step.issue_type.to_s == 'task'
            puts "     #{truncate(step.description, max_length: 60)}" if step.description
          end
        end

        # --- Helpers ---

        def parse_variables
          Array(params[:var]).to_h do |var_str|
            key, value = var_str.split('=', 2)
            raise Eluent::Error, "Invalid variable format '#{var_str}': expected 'name=value'" unless key && value

            [key, value]
          end
        end

        def parse_extraction_mappings
          # For distill: --extract "v2.0=version" means replace "v2.0" with {{version}}
          Array(params[:extract]).to_h do |mapping_str|
            literal, var_name = mapping_str.split('=', 2)
            unless literal && var_name
              raise Eluent::Error, "Invalid extract format '#{mapping_str}': expected 'literal=varname'"
            end

            [literal, var_name]
          end
        end

        def short_id(atom_id)
          atom = repository.find_atom(atom_id)
          atom ? repository.id_resolver.short_id(atom) : atom_id
        end
      end
    end
  end
end
