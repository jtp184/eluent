# frozen_string_literal: true

module Eluent
  module Daemon
    module Concerns
      # Ledger sync command handlers for CommandRouter.
      #
      # This module extracts the `claim` and `ledger_sync` command handlers
      # to keep CommandRouter focused on routing and core command handling.
      #
      # rubocop:disable Metrics/ModuleLength -- cohesive handlers for two related commands
      module LedgerHandlers
        DEFAULT_CLAIM_RETRIES = 5

        private

        # ------------------------------------------------------------------
        # Claim Handler
        # ------------------------------------------------------------------

        # Claims an atom for exclusive work by an agent.
        #
        # @param args [Hash] Must contain:
        #   - :repo_path [String] path to the repository
        #   - :atom_id [String] the atom identifier to claim
        #   - :agent_id [String] the agent claiming the atom
        #   Optional:
        #   - :offline [Boolean] force local-only claim, skip remote sync
        #   - :force [Boolean] steal claim from another agent
        # @return [Hash] Response with claim result
        def handle_claim(args, id)
          repo = get_repository(args[:repo_path])
          atom = repo.find_atom(args[:atom_id])

          raise Registry::IdNotFoundError, args[:atom_id] unless atom

          unless claimable_status?(atom)
            return Protocol.build_error(id: id, code: 'INVALID_STATE',
                                        message: "Cannot claim atom in #{atom.status} state")
          end

          agent_id = normalize_agent_id(args[:agent_id])
          syncer = get_ledger_syncer(args[:repo_path])

          if syncer && !args[:offline]
            claim_with_ledger_sync(id, repo, atom, agent_id, syncer, args[:force])
          else
            claim_locally(id, repo, atom, agent_id, args[:force], syncer)
          end
        end

        # ------------------------------------------------------------------
        # Ledger Sync Handler
        # ------------------------------------------------------------------

        # Handles ledger sync operations.
        #
        # @param args [Hash] Must contain:
        #   - :repo_path [String] path to the repository
        #   - :action [String] one of: 'setup', 'teardown', 'pull', 'push',
        #                      'status', 'reconcile', 'force_resync'
        # @return [Hash] Response with operation result
        def handle_ledger_sync(args, id)
          action = args[:action]
          return error_missing_action(id) if action.nil? || action.to_s.strip.empty?

          dispatch_ledger_action(action.to_s, args, id)
        end

        def dispatch_ledger_action(action, args, id)
          case action
          when 'setup'        then handle_ledger_setup(args, id)
          when 'teardown'     then handle_ledger_teardown(args, id)
          when 'pull'         then handle_ledger_pull(args, id)
          when 'push'         then handle_ledger_push(args, id)
          when 'status'       then handle_ledger_status(args, id)
          when 'reconcile'    then handle_ledger_reconcile(args, id)
          when 'force_resync' then handle_ledger_force_resync(args, id)
          else
            Protocol.build_error(id: id, code: 'INVALID_REQUEST',
                                 message: "Unknown ledger_sync action: #{action}")
          end
        end

        # ------------------------------------------------------------------
        # Ledger Sync Action Handlers
        # ------------------------------------------------------------------

        def handle_ledger_setup(args, id)
          syncer = get_ledger_syncer(args[:repo_path])
          return error_ledger_not_configured(id) unless syncer

          result = syncer.setup!

          if result.success
            Protocol.build_success(id: id, data: {
                                     action: 'setup',
                                     created_branch: result.created_branch,
                                     created_worktree: result.created_worktree
                                   })
          else
            Protocol.build_error(id: id, code: 'SETUP_FAILED', message: result.error)
          end
        end

        def handle_ledger_teardown(args, id)
          syncer = get_ledger_syncer(args[:repo_path])
          return error_ledger_not_configured(id) unless syncer

          syncer.teardown!

          mutex.synchronize { ledger_syncer_cache.delete(args[:repo_path]) }

          state = build_ledger_sync_state(args[:repo_path])
          state.reset! if state.exists?

          Protocol.build_success(id: id, data: { action: 'teardown', success: true })
        end

        def handle_ledger_pull(args, id)
          syncer = get_ledger_syncer(args[:repo_path])
          return error_ledger_not_available(id, syncer) unless syncer&.available?

          result = syncer.pull_ledger

          if result.success
            syncer.sync_to_main
            Protocol.build_success(id: id, data: {
                                     action: 'pull',
                                     changes_applied: result.changes_applied
                                   })
          else
            Protocol.build_error(id: id, code: 'PULL_FAILED', message: result.error)
          end
        end

        def handle_ledger_push(args, id)
          syncer = get_ledger_syncer(args[:repo_path])
          return error_ledger_not_available(id, syncer) unless syncer&.available?

          result = syncer.push_ledger

          if result.success
            Protocol.build_success(id: id, data: {
                                     action: 'push',
                                     changes_applied: result.changes_applied
                                   })
          else
            Protocol.build_error(id: id, code: 'PUSH_FAILED', message: result.error)
          end
        end

        def handle_ledger_status(args, id)
          config = load_sync_config(args[:repo_path])
          syncer = get_ledger_syncer(args[:repo_path])
          state = build_ledger_sync_state(args[:repo_path])
          state.load if state.exists?

          Protocol.build_success(id: id, data: build_status_data(config, syncer, state))
        end

        def build_status_data(config, syncer, state)
          {
            action: 'status',
            configured: !config['ledger_branch'].nil?,
            ledger_branch: config['ledger_branch'],
            available: syncer&.available? || false,
            healthy: syncer&.healthy? || false,
            online: syncer&.online? || false,
            last_pull_at: state.last_pull_at&.iso8601,
            last_push_at: state.last_push_at&.iso8601,
            ledger_head: state.ledger_head,
            valid: state.valid?,
            offline_claims_count: state.offline_claims.size
          }
        end

        def handle_ledger_reconcile(args, id)
          syncer = get_ledger_syncer(args[:repo_path])
          return error_ledger_not_available(id, syncer) unless syncer&.available?

          state = build_ledger_sync_state(args[:repo_path])
          state.load

          return no_offline_claims_response(id) unless state.offline_claims?

          initial_count = state.offline_claims.size
          results = syncer.reconcile_offline_claims!(state: state)

          successful = results.count { |r| r[:success] }
          conflicts = results.count { |r| r[:conflict] }

          Protocol.build_success(id: id, data: {
                                   action: 'reconcile',
                                   offline_claims_count: initial_count,
                                   reconciled: successful,
                                   conflicts: conflicts,
                                   results: results
                                 })
        end

        def no_offline_claims_response(id)
          Protocol.build_success(id: id, data: {
                                   action: 'reconcile',
                                   reconciled: 0,
                                   message: 'No offline claims to reconcile'
                                 })
        end

        def handle_ledger_force_resync(args, id)
          syncer = get_ledger_syncer(args[:repo_path])
          return error_ledger_not_configured(id) unless syncer

          syncer.teardown! if syncer.available?

          state = build_ledger_sync_state(args[:repo_path])
          state.reset!

          setup_result = syncer.setup!
          unless setup_result.success
            return Protocol.build_error(id: id, code: 'RESYNC_FAILED', message: setup_result.error)
          end

          pull_result = syncer.pull_ledger
          unless pull_result.success
            return Protocol.build_error(id: id, code: 'PULL_FAILED', message: pull_result.error)
          end

          syncer.sync_to_main

          Protocol.build_success(id: id, data: { action: 'force_resync', success: true })
        end

        # ------------------------------------------------------------------
        # Claim Helpers
        # ------------------------------------------------------------------

        def claim_with_ledger_sync(id, repo, atom, agent_id, syncer, force)
          unless syncer.available?
            setup_result = syncer.setup!
            return claim_locally(id, repo, atom, agent_id, force, syncer) unless setup_result.success
          end

          result = syncer.claim_and_push(atom_id: atom.id, agent_id: agent_id)

          handle_claim_result(id, repo, atom, agent_id, result, force, syncer)
        end

        def handle_claim_result(id, repo, atom, agent_id, result, force, syncer)
          return claim_success_response(id, atom, result) if result.success

          case result.error
          when /Already claimed/
            force ? claim_locally(id, repo, atom, agent_id, force, syncer) : claim_conflict_response(id, result)
          when /Max retries/
            max_retries_response(id, result)
          else
            Protocol.build_error(id: id, code: 'CLAIM_FAILED', message: result.error || 'Claim operation failed')
          end
        end

        def claim_success_response(id, atom, result)
          Protocol.build_success(id: id, data: {
                                   atom_id: atom.id,
                                   agent_id: result.claimed_by,
                                   offline: result.offline_claim,
                                   retries: result.retries
                                 })
        end

        def claim_conflict_response(id, result)
          Protocol.build_error(id: id, code: 'CLAIM_CONFLICT',
                               message: "Already claimed by #{result.claimed_by || 'another agent'}")
        end

        def max_retries_response(id, result)
          Protocol.build_error(id: id, code: 'MAX_RETRIES',
                               message: "Max retries (#{result.retries}) exhausted due to persistent conflicts")
        end

        def claim_locally(id, repo, atom, agent_id, force, syncer)
          if claimed_by_other?(atom, agent_id) && !force
            return Protocol.build_error(id: id, code: 'CLAIM_CONFLICT',
                                        message: "Already claimed by #{atom.assignee}")
          end

          atom.status = Models::Status[:in_progress]
          atom.assignee = agent_id
          repo.update_atom(atom)

          record_offline_claim(repo, atom.id, agent_id) if syncer

          Protocol.build_success(id: id, data: {
                                   atom_id: atom.id,
                                   agent_id: agent_id,
                                   offline: true,
                                   retries: 0
                                 })
        end

        def claimed_by_other?(atom, agent_id)
          atom.in_progress? && atom.assignee && atom.assignee != agent_id
        end

        def record_offline_claim(repo, atom_id, agent_id)
          state = build_ledger_sync_state(repo.paths.root)
          state.load
          state.record_offline_claim(atom_id: atom_id, agent_id: agent_id, claimed_at: clock.now)
          state.save
        rescue StandardError
          nil # Don't fail the claim if we can't record offline claim
        end

        # Time source for timestamps. Override in tests for deterministic behavior.
        def clock
          Time
        end

        def default_agent_id
          Socket.gethostname
        rescue StandardError
          'unknown'
        end

        def normalize_agent_id(agent_id)
          normalized = agent_id.to_s.strip
          normalized.empty? ? default_agent_id : normalized
        end

        UNCLAIMABLE_STATUSES = %i[closed discard blocked].freeze
        private_constant :UNCLAIMABLE_STATUSES

        def claimable_status?(atom)
          UNCLAIMABLE_STATUSES.none? { |status| atom.send("#{status}?") }
        end

        # ------------------------------------------------------------------
        # Ledger Syncer Management
        # ------------------------------------------------------------------

        def get_ledger_syncer(repo_path)
          return nil if repo_path.nil?

          cached = ledger_syncer_cache[repo_path]
          return cached if cached

          syncer = build_ledger_syncer(repo_path)
          return nil unless syncer

          mutex.synchronize { ledger_syncer_cache[repo_path] ||= syncer }
        end

        def build_ledger_syncer(repo_path)
          repo = get_repository(repo_path)
          config = config_for(repo)
          sync_config = config['sync'] || {}

          return nil unless sync_config['ledger_branch']

          Sync::LedgerSyncer.new(
            repository: repo,
            git_adapter: Sync::GitAdapter.new(repo_path: repo.paths.root),
            global_paths: Storage::GlobalPaths.new(repo_name: config['repo_name']),
            remote: sync_config['remote'] || 'origin',
            max_retries: sync_config['claim_retries'] || DEFAULT_CLAIM_RETRIES,
            branch: sync_config['ledger_branch'],
            claim_timeout_hours: sync_config['claim_timeout_hours']
          )
        end

        def build_ledger_sync_state(repo_path)
          repo = get_repository(repo_path)
          config = config_for(repo)
          global_paths = Storage::GlobalPaths.new(repo_name: config['repo_name'])
          Sync::LedgerSyncState.new(global_paths: global_paths)
        end

        def load_sync_config(repo_path)
          repo = get_repository(repo_path)
          config_for(repo)['sync'] || {}
        end

        def config_for(repo)
          Storage::ConfigLoader.new(paths: repo.paths).load
        end

        # ------------------------------------------------------------------
        # Error Helpers
        # ------------------------------------------------------------------

        def error_missing_action(id)
          Protocol.build_error(id: id, code: 'INVALID_REQUEST',
                               message: 'ledger_sync requires an action parameter')
        end

        def error_ledger_not_configured(id)
          Protocol.build_error(id: id, code: 'LEDGER_NOT_CONFIGURED',
                               message: 'sync.ledger_branch not set in config')
        end

        def error_ledger_not_available(id, syncer)
          if syncer.nil?
            error_ledger_not_configured(id)
          else
            Protocol.build_error(id: id, code: 'LEDGER_NOT_SETUP',
                                 message: 'Ledger sync not initialized. Use action: setup first')
          end
        end
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
