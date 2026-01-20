# frozen_string_literal: true

require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Compaction management commands for archiving old closed items
      class Compact < BaseCommand
        include Formatting

        ACTIONS = %w[run restore].freeze

        usage do
          program 'el compact'
          desc 'Manage compaction of old closed items'
          example 'el compact run --tier 1 [--preview]', 'Compact old items to tier 1 (truncate descriptions)'
          example 'el compact run --tier 2', 'Compact to tier 2 (remove descriptions and comments)'
          example 'el compact restore ID', 'Restore compacted item from git history'
          example 'el compact restore ID --preview', 'Preview what would be restored'
        end

        argument :action do
          optional
          desc 'Action: run, restore (default: run)'
        end

        argument :target do
          optional
          desc 'Atom ID (for restore)'
        end

        option :tier do
          long '--tier TIER'
          desc 'Compaction tier (1 or 2)'
          convert :int
          default 1
        end

        flag :preview do
          long '--preview'
          desc 'Preview compaction without applying'
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

          action = params[:action] || 'run'

          unless ACTIONS.include?(action)
            return error('INVALID_ACTION', "Unknown action: #{action}. Must be one of: #{ACTIONS.join(', ')}")
          end

          send("action_#{action}")
        end

        private

        def action_run
          tier = params[:tier]
          preview = params[:preview]

          return error('INVALID_TIER', 'Tier must be 1 or 2') unless [1, 2].include?(tier)

          compactor = Compaction::Compactor.new(repository: repository)

          if preview
            result = compactor.compact_all(tier: tier, preview: true)
            output_compact_preview(result, tier)
          else
            result = compactor.compact_all(tier: tier)
            output_compact_result(result)
          end

          0
        end

        def action_restore
          atom_id = params[:target]
          return error('MISSING_ID', 'Atom ID required: el compact restore ID') unless atom_id

          if params[:preview]
            restorer = Compaction::Restorer.new(repository: repository)
            preview = restorer.preview_restore(atom_id)
            output_restore_preview(preview)
            return 0
          end

          restorer = Compaction::Restorer.new(repository: repository)
          result = restorer.restore(atom_id)

          success("Restored atom #{short_id(atom_id)} from git history",
                  data: result.to_h)
        end

        # --- Output Helpers ---

        def output_compact_preview(result, tier)
          if @robot_mode
            puts JSON.generate({ status: 'ok', data: result })
            return
          end

          puts @pastel.bold("Compaction Preview (Tier #{tier})")
          puts "Candidates: #{result[:candidate_count]}"
          before = result[:total_description_bytes_before]
          after = result[:total_description_bytes_after]
          puts "Description bytes: #{before} -> #{after}"
          puts "Comments: #{result[:total_comments_before]} -> #{result[:total_comments_after]}"
          puts
          puts @pastel.dim('Run without --preview to apply compaction')
        end

        def output_compact_result(result)
          if @robot_mode
            puts JSON.generate({ status: 'ok', data: result.to_h })
            return
          end

          puts @pastel.bold("Compaction Complete (Tier #{result.tier})")
          puts "Total: #{result.results.size}"
          puts "Success: #{result.success_count}"
          puts "Errors: #{result.error_count}" if result.error_count.positive?
        end

        def output_restore_preview(preview)
          if @robot_mode
            puts JSON.generate({ status: 'ok', data: preview })
            return
          end

          puts @pastel.bold('Restore Preview')
          puts "Atom: #{preview[:atom_id]}"
          puts "Current tier: #{preview[:current][:compaction_tier]}"
          current_len = preview[:current][:description_length]
          restored_len = preview[:restored][:description_length]
          puts "Description: #{current_len} -> #{restored_len} bytes"
          puts "Comments: #{preview[:current][:comment_count]} -> #{preview[:restored][:comment_count]}"
          puts "From commit: #{preview[:commit]}"
        end

        # --- Helpers ---

        def short_id(atom_id)
          atom = repository.find_atom(atom_id)
          atom ? repository.id_resolver.short_id(atom) : atom_id
        end
      end
    end
  end
end
