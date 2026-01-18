# frozen_string_literal: true

require 'tty-table'
require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # List work items with filters
      class List < BaseCommand
        include Formatting

        usage do
          program 'el list'
          desc 'List work items with optional filters'
          example 'el list', 'List all open items'
          example 'el list --status closed', 'List closed items'
          example 'el list --type bug', 'List bugs only'
        end

        option :status do
          short '-s'
          long '--status STATUS'
          desc 'Filter by status (open, in_progress, blocked, deferred, closed)'
        end

        option :type do
          long '--type TYPE'
          desc 'Filter by issue type (task, feature, bug, artifact, epic)'
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

        flag :include_discarded do
          long '--include-discarded'
          desc 'Include discarded items'
        end

        flag :ephemeral do
          short '-e'
          long '--ephemeral'
          desc 'Show only ephemeral items'
        end

        flag :all do
          long '--all'
          desc 'Show all items including closed'
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

          atoms = repository.list_atoms(
            status: params[:all] ? nil : resolve_status(params[:status]),
            issue_type: resolve_issue_type(params[:type]),
            assignee: params[:assignee],
            labels: Array(params[:label]),
            include_discarded: params[:include_discarded]
          )

          # Filter by priority if specified
          atoms = atoms.select { |a| a.priority == params[:priority] } if params[:priority]

          # Default: exclude closed unless --all or --status specified
          atoms = atoms.reject(&:closed?) unless params[:all] || params[:status]

          if @robot_mode
            output_json(atoms)
          else
            output_table(atoms)
          end

          0
        end

        private

        def resolve_status(status_str)
          return nil unless status_str

          Models::Status[status_str.to_sym]
        rescue KeyError
          nil
        end

        def resolve_issue_type(type_str)
          return nil unless type_str

          Models::IssueType[type_str.to_sym]
        rescue KeyError
          nil
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
            puts @pastel.dim('No items found')
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

          puts @pastel.dim("\n#{atoms.size} item(s)")
        end
      end
    end
  end
end
