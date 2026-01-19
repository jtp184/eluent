# frozen_string_literal: true

module Eluent
  module CLI
    module Commands
      # Synchronize with git remote
      class Sync < BaseCommand
        usage do
          program 'el sync'
          desc 'Synchronize with git remote'
          example 'el sync', 'Pull and push changes'
          example 'el sync --pull-only', 'Only pull remote changes'
          example 'el sync --push-only', 'Only push local changes'
          example 'el sync --dry-run', 'Show what would change'
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
          return 1 unless ensure_remote!

          orchestrator = build_orchestrator

          result = orchestrator.sync(
            pull_only: params[:pull_only],
            push_only: params[:push_only],
            dry_run: params[:dry_run],
            force: params[:force]
          )

          output_result(result)
        end

        private

        def ensure_git_repo!
          return true if repository.paths.git_repo?

          error('NO_GIT_REPO', 'Not a git repository')
        end

        def ensure_remote!
          return true if git_adapter.remote?

          error('NO_REMOTE', 'No git remote configured. Add a remote with: git remote add origin <url>')
        end

        def build_orchestrator
          Eluent::Sync::PullFirstOrchestrator.new(
            repository: repository,
            git_adapter: git_adapter,
            sync_state: sync_state
          )
        end

        def git_adapter
          @git_adapter ||= Eluent::Sync::GitAdapter.new(repo_path: repository.paths.root)
        end

        def sync_state
          @sync_state ||= Eluent::Sync::SyncState.new(paths: repository.paths).load
        end

        def output_result(result)
          if @robot_mode
            output_json(result)
          else
            output_text(result)
          end

          result.success? || result.up_to_date? ? 0 : 1
        end

        def output_json(result)
          data = {
            status: result.status.to_s,
            changes: result.changes,
            conflicts: result.conflicts,
            commits: result.commits
          }

          if result.success?
            puts JSON.generate({ status: 'ok', data: data })
          else
            puts JSON.generate({
                                 status: 'error',
                                 error: { code: 'SYNC_FAILED', message: 'Sync completed with conflicts' },
                                 data: data
                               })
          end
        end

        def output_text(result)
          case result.status
          when :up_to_date
            puts "#{@pastel.green('el:')} Already up to date"
          when :success
            output_changes(result)
            puts "#{@pastel.green('el:')} Sync complete"
          when :conflicted
            output_changes(result)
            warn "#{@pastel.yellow('el: warning:')} Sync completed with #{result.conflicts.size} conflicts"
          end
        end

        def output_changes(result)
          return if result.changes.empty?

          puts 'Changes:'
          result.changes.each do |change|
            icon = case change[:type]
                   when :added then @pastel.green('+')
                   when :removed then @pastel.red('-')
                   when :modified then @pastel.yellow('~')
                   else '?'
                   end
            puts "  #{icon} #{change[:record_type]}: #{change[:title] || change[:id]}"
          end
        end
      end
    end
  end
end
