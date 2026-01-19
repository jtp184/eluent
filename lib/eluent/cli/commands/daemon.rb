# frozen_string_literal: true

module Eluent
  module CLI
    module Commands
      # Manage the Eluent daemon
      class Daemon < BaseCommand
        ACTIONS = %w[start stop status].freeze

        usage do
          program 'el daemon'
          desc 'Manage the Eluent daemon'
          example 'el daemon start', 'Start the daemon'
          example 'el daemon start -f', 'Start in foreground'
          example 'el daemon stop', 'Stop the daemon'
          example 'el daemon status', 'Check daemon status'
        end

        argument :action do
          optional
          desc 'Action: start, stop, or status'
        end

        flag :foreground do
          short '-f'
          long '--foreground'
          desc 'Run in foreground (start only)'
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

          action = params[:action] || 'status'

          unless ACTIONS.include?(action)
            return error('INVALID_ACTION', "Unknown action: #{action}. Valid actions: #{ACTIONS.join(', ')}")
          end

          send("action_#{action}")
        end

        private

        def action_start
          server = Eluent::Daemon::Server.new
          server.start(foreground: params[:foreground])
          0
        rescue Eluent::Daemon::AlreadyRunningError => e
          error('DAEMON_RUNNING', e.message)
        end

        def action_stop
          server = Eluent::Daemon::Server.new
          server.stop

          success('Daemon stopped')
        rescue Eluent::Daemon::NotRunningError => e
          error('DAEMON_NOT_RUNNING', e.message)
        end

        def action_status
          server = Eluent::Daemon::Server.new
          status = server.status

          if @robot_mode
            puts JSON.generate({ status: 'ok', data: status })
          elsif status[:running]
            puts "#{@pastel.green('el:')} Daemon running (PID: #{status[:pid]})"
            puts "  Socket: #{status[:socket]}"
          else
            puts "#{@pastel.yellow('el:')} Daemon not running"
          end

          status[:running] ? 0 : 1
        end
      end
    end
  end
end
