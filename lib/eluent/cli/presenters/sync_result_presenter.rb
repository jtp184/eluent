# frozen_string_literal: true

module Eluent
  module CLI
    module Presenters
      # Formats sync operation results for CLI output.
      #
      # Handles both JSON (robot) mode and human-readable text output
      # for standard sync operations.
      class SyncResultPresenter
        def initialize(pastel:)
          @pastel = pastel
        end

        def present(result:, robot_mode:)
          if robot_mode
            output_json(result)
          else
            output_text(result)
          end

          result.success? || result.up_to_date? ? 0 : 1
        end

        private

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
            icon = change_icon(change[:type])
            puts "  #{icon} #{change[:record_type]}: #{change[:title] || change[:id]}"
          end
        end

        def change_icon(type)
          case type
          when :added then @pastel.green('+')
          when :removed then @pastel.red('-')
          when :modified then @pastel.yellow('~')
          else '?'
          end
        end
      end
    end
  end
end
