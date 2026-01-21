# frozen_string_literal: true

require_relative '../../sync/ledger_syncer'
require_relative '../../sync/ledger_sync_state'
require_relative '../../storage/global_paths'
require_relative '../concerns/ledger_sync_support'
require_relative '../presenters/ledger_status_presenter'
require_relative '../presenters/sync_result_presenter'

module Eluent
  module CLI
    module Commands
      # Synchronize with git remote
      class Sync < BaseCommand
        include Concerns::LedgerSyncSupport

        usage do
          program 'el sync'
          desc 'Synchronize with git remote'
          example 'el sync', 'Pull and push changes'
          example 'el sync --pull-only', 'Only pull remote changes'
          example 'el sync --push-only', 'Only push local changes'
          example 'el sync --dry-run', 'Show what would change'
          example 'el sync --setup-ledger', 'Initialize ledger sync branch and worktree'
          example 'el sync --ledger-only', 'Sync only the ledger branch (fast)'
          example 'el sync --status', 'Show ledger sync status'
        end

        flag :pull_only do
          long '--pull-only'
          desc 'Only pull remote changes, do not push'
        end

        flag :push_only do
          long '--push-only'
          desc 'Only push local changes, do not pull'
        end

        flag :dry_run do
          long '--dry-run'
          desc 'Show what would change without applying'
        end

        flag :force do
          short '-f'
          long '--force'
          desc 'Force sync even with in-progress items'
        end

        # ------------------------------------------------------------------
        # Ledger Sync Flags
        # ------------------------------------------------------------------

        flag :setup_ledger do
          long '--setup-ledger'
          desc 'Initialize ledger sync: create branch and worktree'
        end

        flag :ledger_only do
          long '--ledger-only'
          desc 'Fast sync: only pull/push .eluent/, skip code'
        end

        flag :cleanup_ledger do
          long '--cleanup-ledger'
          desc 'Remove ledger worktree and state (disable feature)'
        end

        flag :reconcile do
          long '--reconcile'
          desc 'Push pending offline claims, report conflicts'
        end

        flag :force_resync do
          long '--force-resync'
          desc 'Reset local ledger state from remote (destructive)'
        end

        flag :status do
          long '--status'
          desc 'Show ledger sync health and pending offline claims'
        end

        flag :yes do
          short '-y'
          long '--yes'
          desc 'Confirm destructive operations without prompting'
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
          return 1 unless ensure_git_repo!

          # Handle ledger-specific commands first (some don't need remote)
          return handle_status if params[:status]
          return handle_cleanup_ledger if params[:cleanup_ledger]

          return 1 unless ensure_remote!

          # Ledger operations
          return handle_setup_ledger if params[:setup_ledger]
          return handle_ledger_only if params[:ledger_only]
          return handle_reconcile if params[:reconcile]
          return handle_force_resync if params[:force_resync]

          # Standard sync
          perform_standard_sync
        end

        private

        # ------------------------------------------------------------------
        # Ledger Operations
        # ------------------------------------------------------------------

        def handle_setup_ledger
          return error_ledger_not_configured unless ledger_sync_enabled?

          syncer = build_ledger_syncer
          result = syncer.setup!

          if result.success
            output_setup_success(result)
            0
          else
            error('SETUP_FAILED', result.error)
            1
          end
        end

        def handle_ledger_only
          return error_ledger_not_configured unless ledger_sync_enabled?

          syncer = build_ledger_syncer
          unless syncer.available?
            return error('LEDGER_NOT_SETUP', 'Ledger sync not initialized. Run: el sync --setup-ledger')
          end

          # Pull then push
          pull_result = syncer.pull_ledger
          return error('PULL_FAILED', pull_result.error) unless pull_result.success

          push_result = syncer.push_ledger
          return error('PUSH_FAILED', push_result.error) unless push_result.success

          # Copy to main working tree
          syncer.sync_to_main

          output_ledger_sync_success
          0
        end

        def handle_cleanup_ledger
          return error_ledger_not_configured unless ledger_sync_enabled?

          syncer = build_ledger_syncer

          # Check for uncommitted changes in worktree
          if syncer.available? && !params[:force] && !params[:yes]
            warn 'el: warning: this will remove the ledger worktree and local state'
            warn 'el: use --force or --yes to confirm'
            return 1
          end

          syncer.teardown!
          ledger_sync_state.reset! if ledger_sync_state.exists?

          success('Ledger sync disabled and worktree removed')
        end

        def handle_reconcile
          return error_ledger_not_configured unless ledger_sync_enabled?

          syncer = build_ledger_syncer
          unless syncer.available?
            return error('LEDGER_NOT_SETUP', 'Ledger sync not initialized. Run: el sync --setup-ledger')
          end

          state = ledger_sync_state.load
          return success('No offline claims to reconcile') unless state.offline_claims?

          initial_count = state.offline_claims.size
          results = syncer.reconcile_offline_claims!(state: state)
          output_reconcile_results(results, initial_count)
          0
        end

        def handle_force_resync
          return error_ledger_not_configured unless ledger_sync_enabled?

          unless params[:yes]
            warn 'el: warning: --force-resync will discard local ledger state'
            warn 'el: use --yes to confirm'
            return 1
          end

          syncer = build_ledger_syncer

          # Teardown and re-setup
          syncer.teardown! if syncer.available?
          ledger_sync_state.reset!

          result = syncer.setup!
          return error('RESYNC_FAILED', result.error) unless result.success

          # Pull fresh state from remote
          pull_result = syncer.pull_ledger
          return error('PULL_FAILED', pull_result.error) unless pull_result.success

          syncer.sync_to_main
          success('Ledger state reset from remote')
        end

        def handle_status
          output_ledger_status
          0
        end

        # ------------------------------------------------------------------
        # Standard Sync
        # ------------------------------------------------------------------

        def perform_standard_sync
          orchestrator = build_orchestrator

          result = orchestrator.sync(
            pull_only: params[:pull_only],
            push_only: params[:push_only],
            dry_run: params[:dry_run],
            force: params[:force]
          )

          output_result(result)
        end

        # ------------------------------------------------------------------
        # Validation
        # ------------------------------------------------------------------

        def ensure_git_repo!
          return true if repository.paths.git_repo?

          error('NO_GIT_REPO', 'Not a git repository')
          false
        end

        def ensure_remote!
          return true if git_adapter.remote?

          error('NO_REMOTE', 'No git remote configured. Add a remote with: git remote add origin <url>')
          false
        end

        def error_ledger_not_configured
          error('LEDGER_NOT_CONFIGURED',
                'sync.ledger_branch not set in config. ' \
                'Add `sync: { ledger_branch: "eluent-sync" }` to .eluent/config.yaml')
        end

        # ------------------------------------------------------------------
        # Builders
        # ------------------------------------------------------------------

        def build_orchestrator
          Eluent::Sync::PullFirstOrchestrator.new(
            repository: repository,
            git_adapter: git_adapter,
            sync_state: sync_state
          )
        end

        def sync_state
          @sync_state ||= Eluent::Sync::SyncState.new(paths: repository.paths).load
        end

        def ledger_sync_state
          @ledger_sync_state ||= build_ledger_sync_state
        end

        # ------------------------------------------------------------------
        # Output Helpers
        # ------------------------------------------------------------------

        def output_setup_success(result)
          data = {
            created_branch: result.created_branch,
            created_worktree: result.created_worktree,
            branch: sync_config['ledger_branch'],
            worktree_path: global_paths.sync_worktree_dir
          }

          if @robot_mode
            puts JSON.generate({ status: 'ok', data: data })
          else
            if result.created_branch
              puts "#{@pastel.green('el:')} Created ledger branch: #{sync_config['ledger_branch']}"
            end
            if result.created_worktree
              puts "#{@pastel.green('el:')} Created worktree at: #{global_paths.sync_worktree_dir}"
            end
            unless result.created_branch || result.created_worktree
              puts "#{@pastel.green('el:')} Ledger sync already configured"
            end
          end
        end

        def output_ledger_sync_success
          if @robot_mode
            puts JSON.generate({ status: 'ok', data: { action: 'ledger_sync' } })
          else
            puts "#{@pastel.green('el:')} Ledger synced"
          end
        end

        def output_reconcile_results(results, initial_count)
          successful = results.count { |r| r[:success] }
          conflicts = results.select { |r| r[:conflict] }
          errors = results.reject { |r| r[:success] || r[:conflict] || r[:atom_deleted] }

          data = {
            offline_claims: initial_count,
            reconciled: successful,
            conflicts: conflicts.map { |r| { atom_id: r[:atom_id], error: r[:error] } },
            errors: errors.map { |r| { atom_id: r[:atom_id], error: r[:error] } }
          }

          if @robot_mode
            puts JSON.generate({ status: 'ok', data: data })
          else
            puts "#{@pastel.green('el:')} Reconciled #{successful}/#{initial_count} offline claims"
            conflicts.each do |conflict|
              puts "    #{@pastel.yellow('conflict:')} #{conflict[:atom_id]} - #{conflict[:error]}"
            end
            errors.each do |err|
              puts "    #{@pastel.red('error:')} #{err[:atom_id]} - #{err[:error]}"
            end
          end
        end

        def output_ledger_status
          presenter = Presenters::LedgerStatusPresenter.new(pastel: @pastel)
          presenter.present(
            state: ledger_sync_state.load,
            syncer: ledger_sync_enabled? ? build_ledger_syncer : nil,
            sync_config: sync_config,
            global_paths: global_paths,
            robot_mode: @robot_mode
          )
        end

        def output_result(result)
          presenter = Presenters::SyncResultPresenter.new(pastel: @pastel)
          presenter.present(result: result, robot_mode: @robot_mode)
        end
      end
    end
  end
end
