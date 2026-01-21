# frozen_string_literal: true

require_relative '../../sync/ledger_syncer'
require_relative '../../sync/ledger_sync_state'
require_relative '../../storage/global_paths'
require_relative '../concerns/ledger_sync_support'

module Eluent
  module CLI
    module Commands
      # Claim an atom for exclusive work.
      #
      # When ledger sync is configured, claims are pushed to the remote
      # ledger branch for coordination with other agents. Without ledger
      # sync, claims are local-only.
      #
      # @example Claim an atom
      #   el claim TSV4
      #
      # @example Claim with specific agent ID
      #   el claim TSV4 --agent-id my-agent
      #
      # @example Force local-only claim
      #   el claim TSV4 --offline
      class Claim < BaseCommand
        include Concerns::LedgerSyncSupport

        usage do
          program 'el claim'
          desc 'Claim an atom for exclusive work'
          example 'el claim TSV4', 'Claim atom TSV4'
          example 'el claim TSV4 --agent-id X', 'Claim as specific agent'
          example 'el claim TSV4 --offline', 'Force local-only claim'
          example 'el claim TSV4 --force', 'Steal claim from another agent'
        end

        argument :atom_id do
          required
          desc 'Atom ID (full or short)'
        end

        option :agent_id do
          short '-a'
          long '--agent-id ID'
          desc 'Agent identifier (default: hostname)'
        end

        flag :offline do
          long '--offline'
          desc 'Force local-only claim, skip remote sync'
        end

        flag :force do
          short '-f'
          long '--force'
          desc 'Steal claim from another agent'
        end

        flag :quiet do
          short '-q'
          long '--quiet'
          desc 'Suppress success output'
        end

        flag :help do
          short '-h'
          long '--help'
          desc 'Print usage'
        end

        def run
          return show_help if params[:help]

          ensure_initialized!
          return exit_not_git_repo unless git_repo?

          atom = find_atom
          return exit_atom_not_found unless atom
          return exit_atom_terminal(atom) if terminal_status?(atom)

          claim_atom(atom)
        end

        private

        def show_help
          puts help
          0
        end

        def git_repo?
          repository.paths.git_repo?
        end

        def find_atom
          repository.find_atom(params[:atom_id])
        end

        def terminal_status?(atom)
          atom.closed? || atom.discard?
        end

        def claim_atom(atom)
          if ledger_sync_enabled? && !params[:offline]
            claim_with_ledger_sync(atom)
          else
            claim_locally(atom)
          end
        end

        def claim_with_ledger_sync(atom)
          syncer = build_ledger_syncer
          return exit_ledger_unhealthy(syncer) unless syncer.available? || syncer.setup!.success

          result = syncer.claim_and_push(atom_id: atom.id, agent_id: effective_agent_id)

          if result.success
            output_claim_success(atom, offline: result.offline_claim, retries: result.retries)
          elsif result.error&.include?('Already claimed')
            exit_already_claimed(result.claimed_by)
          elsif result.error&.include?('Max retries')
            exit_max_retries(result.retries)
          else
            exit_claim_failed(result.error)
          end
        end

        def claim_locally(atom)
          current_assignee = atom.assignee

          if atom.in_progress? && current_assignee && current_assignee != effective_agent_id
            return exit_already_claimed(current_assignee) unless params[:force]

            warn_stealing_claim(current_assignee)
          end

          atom.status = Eluent::Models::Status[:in_progress]
          atom.assignee = effective_agent_id
          repository.update_atom(atom)

          record_offline_claim(atom) if ledger_sync_enabled?
          output_claim_success(atom, offline: true)
        end

        def record_offline_claim(atom)
          state = build_ledger_sync_state
          state.load
          state.record_offline_claim(
            atom_id: atom.id,
            agent_id: effective_agent_id,
            claimed_at: clock.now
          )
          state.save
        rescue StandardError => e
          warn "el: warning: could not record offline claim: #{e.message}"
        end

        # Time source for timestamps. Override in tests for deterministic behavior.
        def clock
          Time
        end

        def output_claim_success(atom, offline: false, retries: 0)
          return ExitCodes::SUCCESS if params[:quiet]

          short_id = repository.id_resolver.short_id(atom)
          data = {
            atom_id: atom.id,
            short_id: short_id,
            agent_id: effective_agent_id,
            offline: offline,
            retries: retries
          }

          if @robot_mode
            puts JSON.generate({ status: 'ok', data: data })
          else
            suffix = offline ? ' (offline)' : ''
            puts "#{@pastel.green('el:')} Claimed #{short_id}#{suffix}"
          end

          ExitCodes::SUCCESS
        end

        # ------------------------------------------------------------------
        # Exit Codes
        # ------------------------------------------------------------------

        def exit_not_git_repo
          error('NO_GIT_REPO', 'Not a git repository')
          ExitCodes::LEDGER_NOT_CONFIGURED
        end

        def exit_atom_not_found
          error('NOT_FOUND', "Atom not found: #{params[:atom_id]}")
          ExitCodes::ATOM_NOT_FOUND
        end

        def exit_atom_terminal(atom)
          error('INVALID_STATE', "Cannot claim atom in #{atom.status} state")
          ExitCodes::ATOM_TERMINAL
        end

        def exit_already_claimed(claimed_by)
          error('CLAIM_CONFLICT', "Already claimed by #{claimed_by || 'another agent'}")
          ExitCodes::CLAIM_CONFLICT
        end

        def exit_max_retries(retries)
          error('MAX_RETRIES', "Max retries (#{retries}) exhausted due to persistent conflicts")
          ExitCodes::CLAIM_RETRIES
        end

        def exit_claim_failed(message)
          error('CLAIM_FAILED', message || 'Claim operation failed')
          ExitCodes::CLAIM_CONFLICT
        end

        def exit_ledger_unhealthy(syncer)
          if syncer.online?
            error('LEDGER_ERROR', 'Ledger sync is configured but setup failed. Run: el sync --setup-ledger')
            ExitCodes::LEDGER_NOT_CONFIGURED
          else
            # Fall back to local claim when offline
            warn 'el: warning: remote unreachable, claiming locally'
            atom = find_atom
            claim_locally(atom)
          end
        end

        # ------------------------------------------------------------------
        # Helpers
        # ------------------------------------------------------------------

        def warn_stealing_claim(previous_assignee)
          warn "el: warning: stealing claim from #{previous_assignee}"
        end

        def effective_agent_id
          @effective_agent_id ||= params[:agent_id] || default_agent_id
        end

        def default_agent_id
          Socket.gethostname
        rescue StandardError
          'unknown'
        end
      end

      # Exit codes for claim-related operations.
      # These provide specific error information for scripting and automation.
      module ExitCodes
        SUCCESS = 0               # Claim successful
        CLAIM_CONFLICT = 1        # Atom already claimed by another agent
        CLAIM_RETRIES = 2         # Max retries exhausted (persistent conflict)
        LEDGER_NOT_CONFIGURED = 3 # Ledger sync not configured or unavailable
        ATOM_NOT_FOUND = 4        # Atom does not exist
        ATOM_TERMINAL = 5         # Cannot claim atom in closed/discard state
      end
    end
  end
end
