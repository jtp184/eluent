# frozen_string_literal: true

require 'tty-option'
require 'pastel'
require 'json'

module Eluent
  module CLI
    # Main CLI application entry point
    class Application
      include TTY::Option

      COMMANDS = %w[init create list show update close reopen config].freeze

      usage do
        program 'el'
        desc 'Molecular task tracking for human and synthetic workers'
        example 'el init', 'Initialize a new .eluent directory'
        example 'el create --title "Fix bug"', 'Create a new task'
        example 'el list', 'List all items'
        example 'el show TSV4', 'Show item details by short ID'
      end

      argument :command do
        optional
        desc 'Command to run'
      end

      argument :args do
        optional
        arity zero_or_more
        desc 'Command arguments'
      end

      flag :help do
        short '-h'
        long '--help'
        desc 'Print usage'
      end

      flag :version do
        short '-V'
        long '--version'
        desc 'Print version'
      end

      flag :robot do
        long '--robot'
        desc 'Machine-readable JSON output'
      end

      flag :verbose do
        short '-v'
        long '--verbose'
        desc 'Verbose output'
      end

      flag :debug do
        long '--debug'
        desc 'Debug output'
      end

      def initialize(argv = ARGV)
        @argv = argv
        @pastel = Pastel.new
        @robot_mode = false
      end

      def run
        # Check for global flags first
        @robot_mode = @argv.include?('--robot')

        # Parse global options
        parse(@argv)

        if params[:version]
          output_version
          return 0
        end

        if params[:help] && !params[:command]
          output_help
          return 0
        end

        command = params[:command]

        unless command
          output_help
          return 0
        end

        unless COMMANDS.include?(command)
          error("Unknown command: #{command}")
          return 2
        end

        # Build command-specific args
        command_argv = params[:args] || []
        command_argv << '--help' if params[:help]
        command_argv << '--robot' if @robot_mode
        command_argv << '--verbose' if params[:verbose]
        command_argv << '--debug' if params[:debug]

        execute_command(command, command_argv)
      rescue StandardError => e
        handle_error(e)
      end

      private

      def execute_command(command, argv)
        require_relative "commands/#{command}"
        command_class = Commands.const_get(command.capitalize)
        cmd = command_class.new(argv, robot_mode: @robot_mode)
        cmd.run
      end

      def output_version
        if @robot_mode
          puts JSON.generate({ version: Eluent::VERSION })
        else
          puts "el #{Eluent::VERSION}"
        end
      end

      def output_help
        if @robot_mode
          puts JSON.generate({
                               program: 'el',
                               version: Eluent::VERSION,
                               commands: COMMANDS,
                               usage: help
                             })
        else
          puts help
        end
      end

      def error(message)
        if @robot_mode
          puts JSON.generate({
                               status: 'error',
                               error: {
                                 code: 'INVALID_COMMAND',
                                 message: message
                               }
                             })
        else
          warn "#{@pastel.red('el: error:')} #{message}"
        end
      end

      def handle_error(exception)
        code = case exception
               when Storage::RepositoryNotFoundError then 'REPO_NOT_FOUND'
               when Storage::RepositoryExistsError then 'REPO_EXISTS'
               when Registry::AmbiguousIdError then 'AMBIGUOUS_ID'
               when Registry::IdNotFoundError then 'NOT_FOUND'
               when Models::ValidationError then 'VALIDATION_ERROR'
               when Models::SelfReferenceError then 'SELF_REFERENCE'
               else 'INTERNAL_ERROR'
               end

        exit_code = case code
                    when 'REPO_NOT_FOUND', 'NOT_FOUND' then 3
                    when 'REPO_EXISTS', 'AMBIGUOUS_ID', 'SELF_REFERENCE' then 4
                    when 'VALIDATION_ERROR' then 2
                    else 1
                    end

        if @robot_mode
          response = {
            status: 'error',
            error: {
              code: code,
              message: exception.message
            }
          }

          if exception.is_a?(Registry::AmbiguousIdError)
            response[:error][:details] = {
              candidates: exception.candidates.map(&:to_h)
            }
          end

          puts JSON.generate(response)
        else
          warn "#{@pastel.red("el: error: #{code}:")} #{exception.message}"

          warn exception.backtrace.join("\n") if ENV['EL_DEBUG'] || @argv.include?('--debug')
        end

        exit_code
      end
    end

    # Base class for CLI commands
    class BaseCommand
      include TTY::Option

      def initialize(argv = [], robot_mode: false)
        @argv = argv
        @robot_mode = robot_mode
        @pastel = Pastel.new(enabled: !robot_mode)
        parse(argv)
      end

      def run
        raise NotImplementedError, 'Subclasses must implement #run'
      end

      protected

      def repository
        @repository ||= begin
          repo = Storage::JsonlRepository.new(Dir.pwd)
          repo.load! if repo.initialized?
          repo
        end
      end

      def ensure_initialized!
        return if repository.initialized?

        raise Storage::RepositoryNotFoundError, Dir.pwd
      end

      def output(data)
        if @robot_mode
          puts JSON.generate(data)
        elsif block_given?
          yield
        end
      end

      def success(message = nil, data: nil)
        if @robot_mode
          response = { status: 'ok' }
          response[:data] = data if data
          puts JSON.generate(response)
        elsif message
          puts "#{@pastel.green('el:')} #{message}"
        end
        0
      end

      def error(code, message, details: nil)
        if @robot_mode
          response = {
            status: 'error',
            error: {
              code: code,
              message: message
            }
          }
          response[:error][:details] = details if details
          puts JSON.generate(response)
        else
          warn "#{@pastel.red("el: error: #{code}:")} #{message}"
        end
        1
      end
    end
  end
end
