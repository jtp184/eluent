# frozen_string_literal: true

require 'tty-tree'
require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Dependency management: add, remove, list, tree, check
      class Dep < BaseCommand
        include Formatting

        ACTIONS = %w[add remove list tree check].freeze

        usage do
          program 'el dep'
          desc 'Manage dependencies between work items'
          example 'el dep add SOURCE TARGET', 'Add dependency: SOURCE blocks TARGET'
          example 'el dep add SOURCE TARGET --type waits_for', 'Add waits_for dependency'
          example 'el dep add A B --type related', 'Add informational relationship'
          example 'el dep remove SOURCE TARGET', 'Remove dependency'
          example 'el dep list ID', 'List dependencies for an item'
          example 'el dep tree ID', 'Show dependency tree'
          example 'el dep check', 'Check for issues in dependency graph'
        end

        argument :action do
          required
          desc 'Action: add, remove, list, tree, check'
        end

        argument :source do
          optional
          desc 'Source item ID'
        end

        argument :target do
          optional
          desc 'Target item ID'
        end

        option :type do
          short '-t'
          long '--type TYPE'
          desc 'Type: blocks (default), parent_child, conditional_blocks, waits_for, ' \
               'related, duplicates, discovered_from, replies_to'
          default 'blocks'
        end

        flag :blocking_only do
          short '-b'
          long '--blocking-only'
          desc 'Show only blocking dependencies'
        end

        flag :help do
          short '-h'
          long '--help'
          desc 'Print usage'
        end

        def run
          return 0.tap { puts help } if params[:help]

          action = params[:action]

          unless ACTIONS.include?(action)
            return error('INVALID_ACTION', "Unknown action: #{action}. Must be one of: #{ACTIONS.join(', ')}")
          end

          ensure_initialized!

          send("action_#{action}")
        end

        private

        def action_add
          source_id, target_id = resolve_source_target
          return 1 unless source_id && target_id

          dependency_type = params[:type].to_sym

          # Validate with cycle detector before creating
          graph = Graph::DependencyGraph.new(repository.indexer)
          detector = Graph::CycleDetector.new(graph)

          result = detector.validate_bond(
            source_id: source_id,
            target_id: target_id,
            dependency_type: dependency_type
          )

          unless result[:valid]
            return error('CYCLE_DETECTED',
                         "Adding this dependency would create a cycle: #{result[:cycle_path].join(' -> ')}")
          end

          bond = repository.create_bond(
            source_id: source_id,
            target_id: target_id,
            dependency_type: dependency_type
          )

          success("Dependency created: #{short_id_for(source_id)} --[#{dependency_type}]--> #{short_id_for(target_id)}",
                  data: bond.to_h)
        end

        def action_remove
          source_id, target_id = resolve_source_target
          return 1 unless source_id && target_id

          dependency_type = params[:type].to_sym

          repository.remove_bond(
            source_id: source_id,
            target_id: target_id,
            dependency_type: dependency_type
          )

          success("Dependency removed: #{short_id_for(source_id)} --[#{dependency_type}]--> #{short_id_for(target_id)}",
                  data: { source_id: source_id, target_id: target_id, dependency_type: dependency_type.to_s })
        end

        def action_list
          id = params[:source]
          return error('MISSING_ID', 'Item ID required: el dep list ID') unless id

          atom = repository.find_atom(id)
          return error('NOT_FOUND', "Atom not found: #{id}") unless atom

          bonds = repository.bonds_for(atom.id)

          if @robot_mode
            output_bonds_json(atom, bonds)
          else
            output_bonds_formatted(atom, bonds)
          end

          0
        end

        def action_tree
          id = params[:source]
          return error('MISSING_ID', 'Item ID required: el dep tree ID') unless id

          atom = repository.find_atom(id)
          return error('NOT_FOUND', "Atom not found: #{id}") unless atom

          graph = Graph::DependencyGraph.new(repository.indexer)

          if @robot_mode
            output_tree_json(atom, graph)
          else
            output_tree_formatted(atom, graph)
          end

          0
        end

        def action_check
          graph = Graph::DependencyGraph.new(repository.indexer)
          issues = check_graph_health(graph)

          if @robot_mode
            output_check_json(issues)
          else
            output_check_formatted(issues)
          end

          issues.empty? ? 0 : 1
        end

        def resolve_source_target
          source_input = params[:source]
          target_input = params[:target]

          unless source_input && target_input
            error('MISSING_ARGS', 'Both source and target IDs required: el dep add SOURCE TARGET')
            return [nil, nil]
          end

          source = repository.find_atom(source_input)
          unless source
            error('NOT_FOUND', "Source atom not found: #{source_input}")
            return [nil, nil]
          end

          target = repository.find_atom(target_input)
          unless target
            error('NOT_FOUND', "Target atom not found: #{target_input}")
            return [nil, nil]
          end

          [source.id, target.id]
        end

        def short_id_for(atom_id)
          atom = repository.find_atom_by_id(atom_id)
          atom ? repository.id_resolver.short_id(atom) : atom_id
        end

        def output_bonds_json(atom, bonds)
          puts JSON.generate({
                               status: 'ok',
                               data: {
                                 atom_id: atom.id,
                                 outgoing: bonds[:outgoing].map(&:to_h),
                                 incoming: bonds[:incoming].map(&:to_h)
                               }
                             })
        end

        def output_bonds_formatted(atom, bonds)
          short_id = repository.id_resolver.short_id(atom)
          puts "#{@pastel.bold('Dependencies for')} #{short_id} (#{truncate(atom.title, max_length: 40)})\n\n"

          output_bond_section(bonds[:outgoing], 'Blocks (outgoing)', :target_id)
          output_bond_section(bonds[:incoming], 'Blocked by (incoming)', :source_id)
          puts @pastel.dim('No dependencies') if bonds[:outgoing].empty? && bonds[:incoming].empty?
        end

        def output_bond_section(bonds, title, id_method)
          return if bonds.empty?

          puts "#{@pastel.yellow(title)}:"
          bonds.each do |bond|
            related_id = bond.public_send(id_method)
            related = repository.find_atom_by_id(related_id)
            short_id = related ? repository.id_resolver.short_id(related) : related_id
            title_text = related ? truncate(related.title, max_length: 40) : related_id
            puts "  #{format_dep_type(bond.dependency_type)} #{short_id}: #{title_text}"
          end
          puts
        end

        def output_tree_json(atom, graph)
          descendants = graph.all_descendants(atom.id, blocking_only: params[:blocking_only])
          ancestors = graph.all_ancestors(atom.id, blocking_only: params[:blocking_only])

          puts JSON.generate({
                               status: 'ok',
                               data: {
                                 atom_id: atom.id,
                                 descendants: descendants.to_a,
                                 ancestors: ancestors.to_a
                               }
                             })
        end

        def output_tree_formatted(atom, graph)
          short_id = repository.id_resolver.short_id(atom)
          blocking_only = params[:blocking_only]

          puts @pastel.bold("Dependency tree for #{short_id}")
          puts @pastel.dim("(#{blocking_only ? 'blocking only' : 'all dependencies'})\n")

          renderer = TreeRenderer.new(repository: repository, graph: graph)
          puts renderer.render(atom.id, blocking_only: blocking_only)
        end

        # Helper class for rendering dependency trees
        class TreeRenderer
          include Formatting

          def initialize(repository:, graph:)
            @repository = repository
            @graph = graph
          end

          def render(root_id, blocking_only:)
            tree_data = build_tree_data(root_id, blocking_only)
            TTY::Tree.new(tree_data).render
          end

          private

          attr_reader :repository, :graph

          def build_tree_data(root_id, blocking_only)
            root_atom = repository.find_atom_by_id(root_id)
            { atom_label(root_atom) => build_children(root_id, blocking_only, Set.new([root_id])) }
          end

          def build_children(atom_id, blocking_only, visited)
            dependents = graph.direct_dependents(atom_id)
            dependents = dependents.select(&:blocking?) if blocking_only

            dependents.filter_map do |bond|
              next if visited.include?(bond.target_id)

              visited.add(bond.target_id)
              target_atom = repository.find_atom_by_id(bond.target_id)
              label = atom_label(target_atom)
              sub = build_children(bond.target_id, blocking_only, visited)
              sub.empty? ? label : { label => sub }
            end
          end

          def atom_label(atom)
            return 'unknown' unless atom

            short_id = repository.id_resolver.short_id(atom)
            "#{short_id} [#{atom.status.to_s[0].upcase}] #{truncate(atom.title, max_length: 30)}"
          end
        end

        def check_graph_health(graph)
          issues = []

          # Check for orphan bonds (bonds referencing non-existent atoms)
          repository.indexer.all_bonds.each do |bond|
            source = repository.find_atom_by_id(bond.source_id)
            target = repository.find_atom_by_id(bond.target_id)

            issues << { type: 'orphan_bond', bond: bond.to_h, missing: 'source' } unless source
            issues << { type: 'orphan_bond', bond: bond.to_h, missing: 'target' } unless target
          end

          # Check for closed items with open dependents (potential stale blocks)
          repository.indexer.all_atoms.each do |atom|
            next unless atom.closed?

            graph.direct_dependents(atom.id).each do |bond|
              dependent = repository.find_atom_by_id(bond.target_id)
              next unless dependent && !dependent.closed?

              issues << {
                type: 'stale_block',
                closed_id: atom.id,
                blocked_id: dependent.id,
                dependency_type: bond.dependency_type.to_s
              }
            end
          end

          issues
        end

        def output_check_json(issues)
          puts JSON.generate({
                               status: issues.empty? ? 'ok' : 'warning',
                               data: {
                                 issues_count: issues.size,
                                 issues: issues
                               }
                             })
        end

        def output_check_formatted(issues)
          if issues.empty?
            puts @pastel.green('Dependency graph is healthy')
            return
          end

          puts @pastel.yellow("Found #{issues.size} issue(s):\n")

          issues.each do |issue|
            case issue[:type]
            when 'orphan_bond'
              puts @pastel.red("  Orphan bond: #{issue[:missing]} atom not found")
              puts "    #{issue[:bond][:source_id]} -> #{issue[:bond][:target_id]}"
            when 'stale_block'
              puts @pastel.yellow('  Stale block: closed item still blocking open item')
              closed_short = short_id_for(issue[:closed_id])
              blocked_short = short_id_for(issue[:blocked_id])
              puts "    #{closed_short} --[#{issue[:dependency_type]}]--> #{blocked_short}"
            end
            puts
          end
        end
      end
    end
  end
end
