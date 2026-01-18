# frozen_string_literal: true

require 'tty-prompt'

module Eluent
  module CLI
    module Commands
      # Create a new work item
      class Create < BaseCommand
        usage do
          program 'el create'
          desc 'Create a new work item'
          example 'el create --title "Fix login bug"', 'Create a task with title'
          example 'el create --title "New feature" --type feature', 'Create a feature'
          example 'el create -i', 'Interactive mode'
        end

        option :title do
          short '-t'
          long '--title TITLE'
          desc 'Work item title'
        end

        option :description do
          short '-d'
          long '--description DESC'
          desc 'Work item description'
        end

        option :type do
          long '--type TYPE'
          desc 'Issue type (task, feature, bug, artifact, epic)'
          default 'task'
        end

        option :priority do
          short '-p'
          long '--priority LEVEL'
          desc 'Priority level (0-5, 0 = highest)'
          convert :int
        end

        option :assignee do
          short '-a'
          long '--assignee USER'
          desc 'Assign to user'
        end

        option :label do
          short '-l'
          long '--label LABEL'
          desc 'Add label (can be repeated)'
          arity zero_or_more
        end

        option :parent do
          long '--parent ID'
          desc 'Parent atom ID'
        end

        option :blocking do
          short '-b'
          long '--blocking ID'
          desc 'ID of atom this blocks (creates dependency)'
        end

        flag :ephemeral do
          short '-e'
          long '--ephemeral'
          desc 'Create as ephemeral (local-only, not synced)'
        end

        flag :interactive do
          short '-i'
          long '--interactive'
          desc 'Interactive mode for guided input'
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

          attrs = gather_attributes
          return 2 if attrs.nil?

          atom = repository.create_atom(attrs)

          # Create blocking dependency if specified
          if params[:blocking]
            target = repository.find_atom(params[:blocking])
            if target
              repository.create_bond(
                source_id: target.id,
                target_id: atom.id,
                dependency_type: 'blocks'
              )
            else
              warn "#{@pastel.yellow('el: warning:')} blocking target not found: #{params[:blocking]}"
            end
          end

          short_id = repository.id_resolver.short_id(atom)

          success("Created #{atom.issue_type} #{short_id}: #{atom.title}", data: atom.to_h)
        end

        private

        def gather_attributes
          if params[:interactive] && !@robot_mode && $stdin.tty?
            gather_interactive
          else
            gather_from_params
          end
        end

        def gather_from_params
          title = params[:title]

          if title.nil? || title.strip.empty?
            if @robot_mode
              error('INVALID_REQUEST', 'title is required')
            else
              error('INVALID_REQUEST', 'title is required. Use -i for interactive mode.')
            end
            return nil
          end

          {
            title: title,
            description: params[:description],
            issue_type: params[:type],
            priority: params[:priority],
            assignee: params[:assignee],
            labels: Array(params[:label]),
            parent_id: resolve_parent_id,
            ephemeral: params[:ephemeral]
          }
        end

        def gather_interactive
          prompt = TTY::Prompt.new

          title = prompt.ask('Title:') do |q|
            q.required true
            q.validate(/\S/, 'Title cannot be blank')
          end

          description = prompt.ask('Description (optional):')

          issue_type = prompt.select('Type:', Models::Atom::ISSUE_TYPES)

          priority = prompt.slider('Priority:', min: 0, max: 5, default: 2)

          assignee = prompt.ask('Assignee (optional):')

          labels_input = prompt.ask('Labels (comma-separated, optional):')
          labels = labels_input ? labels_input.split(',').map(&:strip).reject(&:empty?) : []

          ephemeral = prompt.yes?('Ephemeral (local-only)?', default: false)

          {
            title: title,
            description: description,
            issue_type: issue_type,
            priority: priority,
            assignee: assignee.to_s.empty? ? nil : assignee,
            labels: labels,
            parent_id: resolve_parent_id,
            ephemeral: ephemeral
          }
        end

        def resolve_parent_id
          return nil unless params[:parent]

          parent = repository.find_atom(params[:parent])
          parent&.id
        end
      end
    end
  end
end
