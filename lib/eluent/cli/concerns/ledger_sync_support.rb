# frozen_string_literal: true

module Eluent
  module CLI
    module Concerns
      # Shared ledger sync functionality for CLI commands.
      #
      # Commands that work with ledger sync can include this module to get
      # standardized access to the syncer, state, and configuration.
      #
      # @example
      #   class MyCommand < BaseCommand
      #     include Concerns::LedgerSyncSupport
      #
      #     def run
      #       return unless ledger_sync_enabled?
      #       syncer = build_ledger_syncer
      #       # ...
      #     end
      #   end
      module LedgerSyncSupport
        private

        def ledger_sync_enabled?
          !sync_config['ledger_branch'].nil?
        end

        def sync_config
          @sync_config ||= config['sync'] || {}
        end

        def config
          @config ||= Eluent::Storage::ConfigLoader.new(paths: repository.paths).load
        end

        def build_ledger_syncer
          Eluent::Sync::LedgerSyncer.new(
            repository: repository,
            git_adapter: git_adapter,
            global_paths: global_paths,
            remote: sync_config['remote'] || 'origin',
            max_retries: sync_config['claim_retries'] || 5,
            branch: sync_config['ledger_branch'],
            claim_timeout_hours: sync_config['claim_timeout_hours']
          )
        end

        def build_ledger_sync_state
          Eluent::Sync::LedgerSyncState.new(global_paths: global_paths)
        end

        def global_paths
          @global_paths ||= Eluent::Storage::GlobalPaths.new(repo_name: config['repo_name'])
        end

        def git_adapter
          @git_adapter ||= Eluent::Sync::GitAdapter.new(repo_path: repository.paths.root)
        end
      end
    end
  end
end
