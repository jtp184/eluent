# frozen_string_literal: true

module Eluent
  module CLI
    module Commands
      # Reopen a closed work item
      class Reopen < BaseCommand
        usage do
          program 'el reopen'
          desc 'Reopen a closed work item'
          example 'el reopen TSV4', 'Reopen a closed item'
        end

        argument :id do
          required
          desc 'Item ID (full or short)'
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

          unless atom.closed? || atom.discard?
            short_id = repository.id_resolver.short_id(atom)
            return error('CONFLICT', "#{short_id} is not closed (status: #{atom.status})")
          end

          atom.status = 'open'
          atom.close_reason = nil

          repository.update_atom(atom)

          short_id = repository.id_resolver.short_id(atom)
          success("Reopened #{short_id}", data: atom.to_h)
        end
      end
    end
  end
end
