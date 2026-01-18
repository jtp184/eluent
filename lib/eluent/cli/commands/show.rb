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

          output_title_box(atom, short_id)
          output_main_info(atom)
          output_verbose_info(atom, display_info) if params[:verbose]
          output_dependencies(atom) if params[:deps]
          output_comments(atom) if params[:comments]
        end

        def output_title_box(atom, short_id)
          title_box = TTY::Box.frame(
            title: { top_left: " #{format_type(atom.issue_type, upcase: true)} " },
            padding: [0, 1],
            width: 80
          ) do
            "#{@pastel.bold(atom.title)}\n#{@pastel.dim(short_id)}"
          end
          puts title_box
        end

        def output_main_info(atom)
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
        end

        def output_verbose_info(atom, display_info)
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

        def output_dependencies(atom)
          bonds = repository.bonds_for(atom.id)

          puts "\n#{@pastel.bold('Dependencies:')}"

          if bonds[:outgoing].empty? && bonds[:incoming].empty?
            puts @pastel.dim('  No dependencies')
            return
          end

          output_bond_list(bonds[:outgoing], label: @pastel.yellow('Depends on:'), id_method: :target_id)
          output_bond_list(bonds[:incoming], label: @pastel.green('Depended on by:'), id_method: :source_id)
        end

        def output_bond_list(bonds, label:, id_method:)
          return if bonds.empty?

          puts "  #{label}"
          bonds.each do |bond|
            related_id = bond.public_send(id_method)
            related = repository.find_atom_by_id(related_id)
            title = related ? truncate(related.title, max_length: 40) : related_id
            puts "    #{format_dep_type(bond.dependency_type)} #{title}"
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
