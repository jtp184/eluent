# frozen_string_literal: true

module Eluent
  module CLI
    module Presenters
      # Formats ledger sync status for CLI output.
      #
      # Handles both JSON (robot) mode and human-readable text output.
      class LedgerStatusPresenter
        def initialize(pastel:)
          @pastel = pastel
        end

        def present(state:, syncer:, sync_config:, global_paths:, robot_mode:)
          data = build_data(state, syncer, sync_config, global_paths)

          if robot_mode
            puts JSON.generate({ status: 'ok', data: data })
          else
            output_text(data, state)
          end
        end

        private

        def build_data(state, syncer, sync_config, global_paths)
          enabled = !sync_config['ledger_branch'].nil?
          {
            ledger_sync_enabled: enabled,
            ledger_branch: sync_config['ledger_branch'],
            available: syncer&.available? || false,
            healthy: syncer&.healthy? || false,
            online: syncer&.online? || false,
            last_pull_at: state.last_pull_at&.iso8601,
            last_push_at: state.last_push_at&.iso8601,
            ledger_head: state.ledger_head,
            worktree_valid: state.valid?,
            offline_claims_count: state.offline_claims.size,
            worktree_path: enabled ? global_paths.sync_worktree_dir : nil
          }
        end

        def output_text(data, state)
          puts 'Ledger Sync Status'
          puts '─' * 40

          if data[:ledger_sync_enabled]
            output_enabled_status(data, state)
          else
            output_disabled_status
          end
        end

        def output_enabled_status(data, state)
          puts "  Branch:     #{data[:ledger_branch]}"
          puts "  Available:  #{format_bool(data[:available])}"
          puts "  Healthy:    #{format_bool(data[:healthy])}"
          puts "  Online:     #{format_bool(data[:online])}"
          puts "  Last pull:  #{data[:last_pull_at] || 'never'}"
          puts "  Last push:  #{data[:last_push_at] || 'never'}"
          puts "  Worktree:   #{data[:worktree_path]}"

          output_offline_claims(state) if state.offline_claims?
        end

        def output_offline_claims(state)
          puts ''
          puts "  #{@pastel.yellow("Offline claims: #{state.offline_claims.size}")}"
          state.offline_claims.first(5).each do |claim|
            puts "    - #{claim.atom_id} (#{claim.agent_id})"
          end
          puts '    ...' if state.offline_claims.size > 5
        end

        def output_disabled_status
          puts '  Ledger sync is not configured.'
          puts ''
          puts '  To enable, add to .eluent/config.yaml:'
          puts '    sync:'
          puts '      ledger_branch: eluent-sync'
          puts ''
          puts '  Then run: el sync --setup-ledger'
        end

        def format_bool(value)
          value ? @pastel.green('yes') : @pastel.red('no')
        end
      end
    end
  end
end
