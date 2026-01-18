# frozen_string_literal: true

module Eluent
  module CLI
    module Commands
      # Close a work item
      class Close < BaseCommand
        usage do
          program 'el close'
          desc 'Close a work item with a reason'
          example 'el close TSV4 --reason "Completed"', 'Close with reason'
          example 'el close TSV4 -m "Fixed in PR #42"', 'Close with message'
        end

        argument :id do
          required
          desc 'Item ID (full or short)'
        end

        option :reason do
          short '-r'
          long '--reason REASON'
          desc 'Close reason'
        end

        option :message do
          short '-m'
          long '--message MESSAGE'
          desc 'Alias for --reason'
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

          if atom.closed?
            short_id = repository.id_resolver.short_id(atom)
            return error('CONFLICT', "#{short_id} is already closed")
          end

          reason = params[:reason] || params[:message]

          atom.status = 'closed'
          atom.close_reason = reason

          repository.update_atom(atom)

          short_id = repository.id_resolver.short_id(atom)
          success("Closed #{short_id}#{": #{reason}" if reason}", data: atom.to_h)
        end
      end
    end
  end
end
