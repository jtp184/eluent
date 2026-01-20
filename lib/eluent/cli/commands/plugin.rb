# frozen_string_literal: true

require 'tty-table'

module Eluent
  module CLI
    module Commands
      # Manage plugins
      class Plugin < BaseCommand
        usage do
          program 'el plugin'
          desc 'Manage eluent plugins'
          example 'el plugin list', 'List loaded plugins'
          example 'el plugin hooks', 'Show registered hooks'
        end

        argument :subcommand do
          optional
          desc 'Subcommand (list, hooks)'
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

          load_plugins

          case params[:subcommand]
          when 'list', nil
            list_plugins
          when 'hooks'
            list_hooks
          else
            error('INVALID_SUBCOMMAND', "Unknown subcommand: #{params[:subcommand]}")
          end
        end

        private

        def load_plugins
          local_path = repository.data_file_exists? ? repository.root_path : nil
          Plugins.manager.load_all!(local_path: local_path, load_gems: true)
        end

        def list_plugins
          plugins = Plugins.manager.all_plugins

          if @robot_mode
            output_plugins_json(plugins)
          else
            output_plugins_table(plugins)
          end

          0
        end

        def list_hooks
          hooks = Plugins.manager.hooks.all_entries

          if @robot_mode
            output_hooks_json(hooks)
          else
            output_hooks_table(hooks)
          end

          0
        end

        def output_plugins_json(plugins)
          puts JSON.generate({
                               status: 'ok',
                               data: {
                                 count: plugins.size,
                                 plugins: plugins.map do |p|
                                   {
                                     name: p.name,
                                     path: p.path,
                                     loaded_at: p.loaded_at.iso8601,
                                     hooks: p.hook_count,
                                     commands: p.command_names
                                   }
                                 end
                               }
                             })
        end

        def output_plugins_table(plugins)
          if plugins.empty?
            puts @pastel.dim('No plugins loaded')
            return
          end

          headers = %w[Name Path Hooks Commands]

          rows = plugins.map do |plugin|
            [
              plugin.name,
              truncate_path(plugin.path),
              plugin.hook_count.to_s,
              plugin.command_names.join(', ')
            ]
          end

          table = TTY::Table.new(header: headers, rows: rows)
          puts render_table(table)
          puts @pastel.dim("\n#{plugins.size} plugin(s)")
        end

        def output_hooks_json(hooks)
          hook_data = hooks.transform_values do |entries|
            entries.map { |e| { plugin: e.plugin_name, priority: e.priority } }
          end

          puts JSON.generate({
                               status: 'ok',
                               data: { hooks: hook_data }
                             })
        end

        def output_hooks_table(hooks)
          registered_hooks = hooks.select { |_, entries| entries.any? }

          if registered_hooks.empty?
            puts @pastel.dim('No hooks registered')
            return
          end

          headers = %w[Hook Plugin Priority]
          rows = []

          registered_hooks.each do |hook_name, entries|
            entries.each do |entry|
              rows << [hook_name.to_s, entry.plugin_name, entry.priority.to_s]
            end
          end

          table = TTY::Table.new(header: headers, rows: rows)
          puts render_table(table)
          puts @pastel.dim("\n#{rows.size} hook(s) registered")
        end

        def truncate_path(path)
          return '' unless path

          path.length > 40 ? "...#{path[-37..]}" : path
        end

        def render_table(table)
          # Use basic rendering when stdout is not a TTY to avoid ioctl errors
          if $stdout.respond_to?(:tty?) && $stdout.tty?
            table.render(:unicode, padding: [0, 1]) do |renderer|
              renderer.border.style = :dim
            end
          else
            table.render(:basic, padding: [0, 1], width: 120)
          end
        end
      end
    end
  end
end
