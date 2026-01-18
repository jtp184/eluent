# frozen_string_literal: true

require 'tty-table'
require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Show ready work items with filtering and sorting
      class Ready < BaseCommand
        include Formatting

        usage do
          program 'el ready'
          desc 'Show ready work items (not blocked, not closed, not abstract)'
          example 'el ready', 'Show all ready items sorted by priority'
          example 'el ready --sort oldest', 'Show ready items sorted by age'
          example 'el ready --type bug', 'Show ready bugs only'
        end

        option :sort do
          long '--sort POLICY'
          desc 'Sort policy: priority, oldest, hybrid (default: priority)'
          default 'priority'
        end

        option :type do
          long '--type TYPE'
          desc 'Filter by issue type'
        end

        option :exclude_type do
          long '--exclude-type TYPE'
          desc 'Exclude issue type (can be repeated)'
          arity zero_or_more
        end

        option :assignee do
          short '-a'
          long '--assignee USER'
          desc 'Filter by assignee'
        end

        option :label do
          short '-l'
          long '--label LABEL'
          desc 'Filter by label (can be repeated)'
          arity zero_or_more
        end

        option :priority do
          short '-p'
          long '--priority LEVEL'
          desc 'Filter by priority level'
          convert :int
        end

        flag :include_abstract do
          long '--include-abstract'
          desc 'Include abstract types (epic, formula)'
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

          ensure_initialized!

          calculator = build_readiness_calculator
          atoms = calculator.ready_items(
            sort: params[:sort].to_sym,
            type: params[:type],
            exclude_types: Array(params[:exclude_type]),
            assignee: params[:assignee],
            labels: Array(params[:label]),
            priority: params[:priority],
            include_abstract: params[:include_abstract]
          )

          if @robot_mode
            output_json(atoms)
          else
            output_table(atoms)
          end

          0
        end

        private

        def build_readiness_calculator
          indexer = repository.indexer
          dependency_graph = Graph::DependencyGraph.new(indexer)
          blocking_resolver = Graph::BlockingResolver.new(
            indexer: indexer,
            dependency_graph: dependency_graph
          )
          Lifecycle::ReadinessCalculator.new(
            indexer: indexer,
            blocking_resolver: blocking_resolver
          )
        end

        def output_json(atoms)
          puts JSON.generate({
                               status: 'ok',
                               data: {
                                 count: atoms.size,
                                 items: atoms.map(&:to_h)
                               }
                             })
        end

        def output_table(atoms)
          if atoms.empty?
            puts @pastel.dim('No ready items found')
            return
          end

          headers = %w[ID Type Pri Status Title]

          rows = atoms.map do |atom|
            short_id = repository.id_resolver.short_id(atom)
            [
              short_id,
              format_type(atom.issue_type),
              format_priority(atom.priority),
              format_status(atom.status),
              truncate(atom.title, max_length: 50)
            ]
          end

          table = TTY::Table.new(header: headers, rows: rows)
          puts table.render(:unicode, padding: [0, 1]) do |renderer|
            renderer.border.style = :dim
          end

          puts @pastel.dim("\n#{atoms.size} ready item(s)")
        end
      end
    end
  end
end
