# frozen_string_literal: true

require 'tty-table'
require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Soft delete management: discard, list, restore, prune
      class Discard < BaseCommand
        include Formatting

        ACTIONS = %w[list restore prune].freeze
        DEFAULT_PRUNE_DAYS = 30

        usage do
          program 'el discard'
          desc 'Soft delete work items (reversible)'
          example 'el discard ID', 'Discard an item'
          example 'el discard list', 'List all discarded items'
          example 'el discard restore ID', 'Restore a discarded item'
          example 'el discard prune --days 30', 'Permanently delete items discarded >30 days ago'
        end

        argument :action_or_id do
          required
          desc 'Action (list, restore, prune) or item ID to discard'
        end

        argument :item_id do
          optional
          desc 'Item ID (for restore action)'
        end

        option :days do
          long '--days DAYS'
          desc 'Prune threshold in days (default: 30)'
          convert :int
          default DEFAULT_PRUNE_DAYS
        end

        flag :all do
          long '--all'
          desc 'Include all discarded items (for list)'
        end

        flag :ephemeral do
          short '-e'
          long '--ephemeral'
          desc 'Only show/prune ephemeral items'
        end

        flag :force do
          short '-f'
          long '--force'
          desc 'Skip confirmation for prune'
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

          action = params[:action_or_id]

          case action
          when 'list' then action_list
          when 'restore' then action_restore
          when 'prune' then action_prune
          else
            # Default: treat as item ID to discard
            action_discard(action)
          end
        end

        private

        def action_discard(item_id)
          atom = repository.find_atom(item_id)
          return error('NOT_FOUND', "Atom not found: #{item_id}") unless atom

          if atom.discard?
            return error('ALREADY_DISCARDED', "Item is already discarded: #{item_id}")
          end

          # Update atom status to discard
          atom.status = Models::Status[:discard]
          atom.updated_at = Time.now.utc
          repository.update_atom(atom)

          short_id = repository.id_resolver.short_id(atom)
          success("Discarded: #{short_id} (#{truncate(atom.title, max_length: 40)})", data: atom.to_h)
        end

        def action_list
          atoms = repository.indexer.all_atoms.select(&:discard?)

          atoms = atoms.select { |a| ephemeral?(a) } if params[:ephemeral]

          if @robot_mode
            output_list_json(atoms)
          else
            output_list_formatted(atoms)
          end

          0
        end

        def action_restore
          item_id = params[:item_id]
          return error('MISSING_ID', 'Item ID required: el discard restore ID') unless item_id

          atom = repository.find_atom(item_id)
          return error('NOT_FOUND', "Atom not found: #{item_id}") unless atom

          unless atom.discard?
            return error('NOT_DISCARDED', "Item is not discarded: #{item_id}")
          end

          # Restore to open status
          atom.status = Models::Status[:open]
          atom.updated_at = Time.now.utc
          repository.update_atom(atom)

          short_id = repository.id_resolver.short_id(atom)
          success("Restored: #{short_id} (#{truncate(atom.title, max_length: 40)})", data: atom.to_h)
        end

        def action_prune
          days = params[:days]
          cutoff = Time.now.utc - (days * 24 * 60 * 60)

          atoms_to_prune = repository.indexer.all_atoms.select do |atom|
            next false unless atom.discard?
            next false if params[:ephemeral] && !ephemeral?(atom)

            atom.updated_at < cutoff
          end

          if atoms_to_prune.empty?
            return success("No discarded items older than #{days} days to prune")
          end

          unless params[:force] || @robot_mode
            puts "About to permanently delete #{atoms_to_prune.size} item(s):"
            atoms_to_prune.each do |atom|
              short_id = repository.id_resolver.short_id(atom)
              puts "  #{short_id}: #{truncate(atom.title, max_length: 50)}"
            end
            puts
            print @pastel.yellow('Continue? [y/N] ')
            response = $stdin.gets&.strip&.downcase
            return 0 unless response == 'y'
          end

          pruned_ids = []
          atoms_to_prune.each do |atom|
            pruned_ids << atom.id
            permanently_delete_atom(atom)
          end

          success("Pruned #{pruned_ids.size} item(s)", data: { pruned_count: pruned_ids.size, pruned_ids: pruned_ids })
        end

        def ephemeral?(atom)
          repository.indexer.source_file_for(atom.id)&.include?('ephemeral')
        end

        def permanently_delete_atom(atom)
          # Remove associated bonds
          repository.indexer.bonds_from(atom.id).each do |bond|
            repository.remove_bond(
              source_id: bond.source_id,
              target_id: bond.target_id,
              dependency_type: bond.dependency_type
            )
          end

          repository.indexer.bonds_to(atom.id).each do |bond|
            repository.remove_bond(
              source_id: bond.source_id,
              target_id: bond.target_id,
              dependency_type: bond.dependency_type
            )
          end

          # Remove the atom from storage
          repository.delete_atom(atom)
        end

        def output_list_json(atoms)
          puts JSON.generate({
                               status: 'ok',
                               data: {
                                 count: atoms.size,
                                 items: atoms.map(&:to_h)
                               }
                             })
        end

        def output_list_formatted(atoms)
          if atoms.empty?
            puts @pastel.dim('No discarded items')
            return
          end

          headers = %w[ID Type Age Title]

          rows = atoms.map do |atom|
            short_id = repository.id_resolver.short_id(atom)
            age = format_age(atom.updated_at)
            [
              short_id,
              format_type(atom.issue_type),
              age,
              truncate(atom.title, max_length: 50)
            ]
          end

          table = TTY::Table.new(header: headers, rows: rows)
          puts table.render(:unicode, padding: [0, 1]) do |renderer|
            renderer.border.style = :dim
          end

          puts @pastel.dim("\n#{atoms.size} discarded item(s)")
        end

        def format_age(time)
          return 'unknown' unless time

          seconds = Time.now.utc - time
          days = (seconds / 86_400).to_i

          case days
          when 0 then 'today'
          when 1 then '1 day'
          else "#{days} days"
          end
        end
      end
    end
  end
end
