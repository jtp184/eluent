# frozen_string_literal: true

require_relative '../formatting'

module Eluent
  module CLI
    module Commands
      # Comment management: add, list
      class Comment < BaseCommand
        include Formatting

        ACTIONS = %w[add list].freeze

        usage do
          program 'el comment'
          desc 'Manage comments on work items'
          example 'el comment add ID "Comment content"', 'Add a comment to an item'
          example 'el comment add ID "Content" --author user@example.com', 'Add comment with author'
          example 'el comment list ID', 'List comments for an item'
        end

        argument :action do
          required
          desc 'Action: add, list'
        end

        argument :item_id do
          required
          desc 'Item ID to add comment to or list comments for'
        end

        argument :content do
          optional
          desc 'Comment content (required for add)'
        end

        option :author do
          short '-a'
          long '--author AUTHOR'
          desc 'Comment author (default: current user from git config or system)'
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

          action = params[:action]

          unless ACTIONS.include?(action)
            return error('INVALID_ACTION', "Unknown action: #{action}. Must be one of: #{ACTIONS.join(', ')}")
          end

          ensure_initialized!

          send("action_#{action}")
        end

        private

        def action_add
          item_id = params[:item_id]
          content = params[:content]

          return error('MISSING_CONTENT', 'Comment content required: el comment add ID "content"') unless content

          atom = repository.find_atom(item_id)
          return error('NOT_FOUND', "Atom not found: #{item_id}") unless atom

          author = params[:author] || resolve_default_author

          comment = repository.create_comment(
            parent_id: atom.id,
            author: author,
            content: content
          )

          short_id = repository.id_resolver.short_id(atom)
          success("Comment added to #{short_id}", data: comment.to_h)
        end

        def action_list
          item_id = params[:item_id]

          atom = repository.find_atom(item_id)
          return error('NOT_FOUND', "Atom not found: #{item_id}") unless atom

          comments = repository.comments_for(atom.id)

          if @robot_mode
            output_comments_json(atom, comments)
          else
            output_comments_formatted(atom, comments)
          end

          0
        end

        def resolve_default_author
          # Try git config first
          git_email = `git config user.email 2>/dev/null`.strip
          return git_email unless git_email.empty?

          # Fall back to system user
          ENV['USER'] || 'anonymous'
        end

        def output_comments_json(atom, comments)
          puts JSON.generate({
                               status: 'ok',
                               data: {
                                 atom_id: atom.id,
                                 count: comments.size,
                                 comments: comments.map(&:to_h)
                               }
                             })
        end

        def output_comments_formatted(atom, comments)
          short_id = repository.id_resolver.short_id(atom)
          puts "#{@pastel.bold('Comments for')} #{short_id} (#{truncate(atom.title, max_length: 40)})\n\n"

          if comments.empty?
            puts @pastel.dim('No comments')
            return
          end

          comments.each_with_index do |comment, idx|
            output_single_comment(comment, idx + 1)
          end

          puts @pastel.dim("\n#{comments.size} comment(s)")
        end

        def output_single_comment(comment, index)
          timestamp = comment.created_at.strftime('%Y-%m-%d %H:%M')
          puts "#{@pastel.cyan("[#{index}]")} #{@pastel.bold(comment.author)} #{@pastel.dim("(#{timestamp})")}"
          puts "  #{comment.content}"
          puts
        end
      end
    end
  end
end
