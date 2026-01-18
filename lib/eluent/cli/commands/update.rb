# frozen_string_literal: true

require 'time'

module Eluent
  module CLI
    module Commands
      # Update work item fields
      class Update < BaseCommand
        SIMPLE_FIELDS = {
          title: :title,
          description: :description,
          type: :issue_type,
          priority: :priority,
          status: :status,
          assignee: :assignee
        }.freeze

        usage do
          program 'el update'
          desc 'Update work item fields'
          example 'el update TSV4 --title "New title"', 'Update title'
          example 'el update TSV4 --status in_progress', 'Change status'
          example 'el update TSV4 --label auth --label security', 'Add labels'
        end

        argument :id do
          required
          desc 'Item ID (full or short)'
        end

        option :title do
          short '-t'
          long '--title TITLE'
          desc 'Update title'
        end

        option :description do
          short '-d'
          long '--description DESC'
          desc 'Update description'
        end

        option :type do
          long '--type TYPE'
          desc 'Change issue type'
        end

        option :priority do
          short '-p'
          long '--priority LEVEL'
          desc 'Update priority (0-5)'
          convert :int
        end

        option :assignee do
          short '-a'
          long '--assignee USER'
          desc 'Assign/reassign to user'
        end

        option :status do
          short '-s'
          long '--status STATUS'
          desc 'Change status directly'
        end

        option :label do
          short '-l'
          long '--label LABEL'
          desc 'Add label (can be repeated)'
          arity zero_or_more
        end

        option :remove_label do
          long '--remove-label LABEL'
          desc 'Remove label'
          arity zero_or_more
        end

        option :defer_until do
          long '--defer-until DATE'
          desc 'Defer until date (ISO 8601)'
        end

        flag :persist do
          long '--persist'
          desc 'Convert ephemeral atom to persistent'
        end

        flag :clear_assignee do
          long '--clear-assignee'
          desc 'Remove assignee'
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

          changes = {}
          apply_simple_updates(atom, changes)
          apply_special_updates(atom, changes)
          apply_label_changes(atom, changes)

          return error('INVALID_REQUEST', 'No changes specified') if changes.empty? && !params[:persist]

          apply_persist(atom, changes)
          repository.update_atom(atom)

          short_id = repository.id_resolver.short_id(atom)
          success("Updated #{short_id}", data: { id: atom.id, changes: changes })
        end

        private

        def apply_simple_updates(atom, changes)
          SIMPLE_FIELDS.each do |param_key, attr_key|
            next unless params[param_key]

            atom.public_send(:"#{attr_key}=", params[param_key])
            changes[attr_key] = params[param_key]
          end
        end

        def apply_special_updates(atom, changes)
          if params[:clear_assignee]
            atom.assignee = nil
            changes[:assignee] = nil
          end

          return unless params[:defer_until]

          atom.defer_until = Time.parse(params[:defer_until])
          changes[:defer_until] = params[:defer_until]
        end

        def apply_label_changes(atom, changes)
          Array(params[:label]).each do |label|
            atom.labels << label
            (changes[:added_labels] ||= []) << label
          end

          Array(params[:remove_label]).each do |label|
            atom.labels.delete(label)
            (changes[:removed_labels] ||= []) << label
          end
        end

        def apply_persist(atom, changes)
          return unless params[:persist]

          repository.persist_atom(atom.id)
          changes[:persisted] = true
        end
      end
    end
  end
end
