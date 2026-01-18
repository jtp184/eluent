# frozen_string_literal: true

require 'tty-box'
require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Show detailed item information
      class Show < BaseCommand
        include Formatting

        usage do
          program 'el show'
          desc 'Show detailed information about a work item'
          example 'el show TSV4', 'Show item by short ID'
          example 'el show eluent-01ARZ3NDEKTSV4RRFFQ69G5FAV', 'Show item by full ID'
        end

        argument :id do
          required
          desc 'Item ID (full or short)'
        end

        flag :verbose do
          short '-v'
          long '--verbose'
          desc 'Show additional details including timestamps'
        end

        flag :comments do
          short '-c'
          long '--comments'
          desc 'Show comments'
        end

        flag :deps do
          short '-d'
          long '--deps'
          desc 'Show dependencies'
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

          atom = repository.find_atom(params[:id])

          return error('NOT_FOUND', "Atom not found: #{params[:id]}") unless atom

          if @robot_mode
            output_json(atom)
          else
            output_formatted(atom)
          end

          0
        end

        private

        def output_json(atom)
          data = atom.to_h
          data[:comments] = repository.comments_for(atom.id).map(&:to_h) if params[:comments]

          if params[:deps]
            bonds = repository.bonds_for(atom.id)
            data[:dependencies] = {
              outgoing: bonds[:outgoing].map(&:to_h),
              incoming: bonds[:incoming].map(&:to_h)
            }
          end

          puts JSON.generate({
                               status: 'ok',
                               data: data
                             })
        end

        def output_formatted(atom)
          display_info = repository.id_resolver.display_info(atom)
          short_id = display_info&.dig(:short) || atom.id

          # Title box
          title_box = TTY::Box.frame(
            title: { top_left: " #{format_type(atom.issue_type, upcase: true)} " },
            padding: [0, 1],
            width: 80
          ) do
            "#{@pastel.bold(atom.title)}\n#{@pastel.dim(short_id)}"
          end
          puts title_box

          # Main info
          puts "\n#{@pastel.bold('Status:')} #{format_status(atom.status)}"
          puts "#{@pastel.bold('Priority:')} #{format_priority_with_label(atom.priority)}"
          puts "#{@pastel.bold('Assignee:')} #{atom.assignee || @pastel.dim('unassigned')}"

          if atom.labels.any?
            labels = atom.labels.map { |l| @pastel.cyan("[#{l}]") }.join(' ')
            puts "#{@pastel.bold('Labels:')} #{labels}"
          end

          if atom.description
            puts "\n#{@pastel.bold('Description:')}"
            puts atom.description
          end

          puts "\n#{@pastel.bold('Close Reason:')} #{atom.close_reason}" if atom.close_reason

          puts "#{@pastel.bold('Deferred Until:')} #{atom.defer_until}" if atom.defer_until

          # Verbose mode - show IDs and timestamps
          if params[:verbose]
            puts "\n#{@pastel.dim('─' * 40)}"
            puts @pastel.dim("Full ID:   #{atom.id}")
            if display_info
              puts @pastel.dim("Timestamp: #{display_info[:timestamp]} (#{display_info[:created_time]})")
              puts @pastel.dim("Random:    #{display_info[:randomness]}")
            end
            puts @pastel.dim("Created:   #{atom.created_at}")
            puts @pastel.dim("Updated:   #{atom.updated_at}")
            puts @pastel.dim("Parent:    #{atom.parent_id || 'none'}")
          end

          # Dependencies
          output_dependencies(atom) if params[:deps]

          # Comments
          return unless params[:comments]

          output_comments(atom)
        end

        def output_dependencies(atom)
          bonds = repository.bonds_for(atom.id)

          puts "\n#{@pastel.bold('Dependencies:')}"

          if bonds[:outgoing].empty? && bonds[:incoming].empty?
            puts @pastel.dim('  No dependencies')
            return
          end

          if bonds[:outgoing].any?
            puts "  #{@pastel.yellow('Depends on:')}"
            bonds[:outgoing].each do |bond|
              target = repository.find_atom_by_id(bond.target_id)
              target_title = target ? truncate(target.title, max_length: 40) : bond.target_id
              puts "    #{format_dep_type(bond.dependency_type)} #{target_title}"
            end
          end

          return unless bonds[:incoming].any?

          puts "  #{@pastel.green('Depended on by:')}"
          bonds[:incoming].each do |bond|
            source = repository.find_atom_by_id(bond.source_id)
            source_title = source ? truncate(source.title, max_length: 40) : bond.source_id
            puts "    #{format_dep_type(bond.dependency_type)} #{source_title}"
          end
        end

        def output_comments(atom)
          comments = repository.comments_for(atom.id)

          puts "\n#{@pastel.bold('Comments:')}"

          if comments.empty?
            puts @pastel.dim('  No comments')
            return
          end

          comments.each_with_index do |comment, idx|
            puts "  #{@pastel.cyan("[#{idx + 1}]")} #{@pastel.bold(comment.author)} " \
                 "#{@pastel.dim("(#{comment.created_at})")}"
            puts "  #{comment.content}"
            puts
          end
        end

        def format_dep_type(type)
          type_str = type.to_s
          colors = {
            'blocks' => :red,
            'parent_child' => :blue,
            'conditional_blocks' => :yellow,
            'waits_for' => :magenta,
            'related' => :cyan,
            'duplicates' => :dim,
            'discovered_from' => :green,
            'replies_to' => :white
          }
          @pastel.decorate("[#{type_str}]", colors[type_str] || :white)
        end
      end
    end
  end
end
