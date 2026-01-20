# frozen_string_literal: true

require 'tty-option'
require 'pastel'
require 'json'

module Eluent
  module CLI
    # Main CLI application entry point
    class Application
      include TTY::Option

      COMMANDS = %w[
        init create list show update close reopen
        config ready dep comment discard sync daemon
        formula compact plugin
      ].freeze

      ERROR_CODES = {
        Storage::RepositoryNotFoundError => 'REPO_NOT_FOUND',
        Storage::RepositoryExistsError => 'REPO_EXISTS',
        Registry::AmbiguousIdError => 'AMBIGUOUS_ID',
        Registry::IdNotFoundError => 'NOT_FOUND',
        Models::ValidationError => 'VALIDATION_ERROR',
        Models::SelfReferenceError => 'SELF_REFERENCE',
        Graph::CycleDetectedError => 'CYCLE_DETECTED',
        Models::InvalidTransitionError => 'INVALID_TRANSITION',
        Sync::GitError => 'GIT_ERROR',
        Sync::NoRemoteError => 'NO_REMOTE',
        Daemon::AlreadyRunningError => 'DAEMON_RUNNING',
        Daemon::NotRunningError => 'DAEMON_NOT_RUNNING',
        Daemon::ProtocolError => 'PROTOCOL_ERROR',
        Daemon::ConnectionError => 'CONNECTION_ERROR',
        Daemon::TimeoutError => 'TIMEOUT',
        Formulas::FormulaNotFoundError => 'NOT_FOUND',
        Formulas::ParseError => 'PARSE_ERROR',
        Formulas::VariableError => 'VALIDATION_ERROR',
        Compaction::CompactionError => 'COMPACTION_ERROR',
        Compaction::RestoreError => 'RESTORE_ERROR',
        Plugins::PluginLoadError => 'PLUGIN_ERROR',
        Plugins::HookAbortError => 'HOOK_ABORTED',
        Agents::ConfigurationError => 'CONFIG_ERROR',
        Agents::AuthenticationError => 'AUTH_ERROR',
        Agents::RateLimitError => 'RATE_LIMIT',
        Agents::ExecutionError => 'EXECUTION_ERROR'
      }.freeze

      EXIT_CODES = {
        'REPO_NOT_FOUND' => 3, 'NOT_FOUND' => 3,
        'REPO_EXISTS' => 4, 'AMBIGUOUS_ID' => 4, 'SELF_REFERENCE' => 4, 'CYCLE_DETECTED' => 4,
        'VALIDATION_ERROR' => 2, 'INVALID_TRANSITION' => 2, 'PARSE_ERROR' => 2,
        'GIT_ERROR' => 5, 'NO_REMOTE' => 5,
        'DAEMON_RUNNING' => 6, 'DAEMON_NOT_RUNNING' => 6, 'PROTOCOL_ERROR' => 6,
        'CONNECTION_ERROR' => 7, 'TIMEOUT' => 7,
        'COMPACTION_ERROR' => 8, 'RESTORE_ERROR' => 8,
        'PLUGIN_ERROR' => 9, 'HOOK_ABORTED' => 9,
        'CONFIG_ERROR' => 10, 'AUTH_ERROR' => 10, 'RATE_LIMIT' => 10, 'EXECUTION_ERROR' => 10
      }.freeze

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

        # Extract command-specific args from original argv (after command name)
        # This avoids TTY::Option consuming subcommand options
        command_argv = extract_subcommand_args(command)
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

      def extract_subcommand_args(command)
        # Find command position in original argv, return everything after it
        # Skip global flags that appear before the command
        global_flags = %w[--robot --verbose -v --debug --help -h --version -V]
        command_idx = @argv.find_index(command)
        return [] unless command_idx

        @argv[(command_idx + 1)..].reject { |arg| global_flags.include?(arg) }
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
        code = ERROR_CODES.find { |klass, _| exception.is_a?(klass) }&.last || 'INTERNAL_ERROR'
        exit_code = EXIT_CODES[code] || 1

        @robot_mode ? output_error_json(exception, code) : output_error_text(exception, code)

        exit_code
      end

      def output_error_json(exception, code)
        response = { status: 'error', error: { code: code, message: exception.message } }

        if exception.is_a?(Registry::AmbiguousIdError)
          response[:error][:details] = { candidates: exception.candidates.map(&:to_h) }
        end

        puts JSON.generate(response)
      end

      def output_error_text(exception, code)
        warn "#{@pastel.red("el: error: #{code}:")} #{exception.message}"
        warn exception.backtrace.join("\n") if ENV['EL_DEBUG'] || @argv.include?('--debug')
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
          repo.load! if repo.data_file_exists?
          repo
        end
      end

      def ensure_initialized!
        return if repository.data_file_exists?

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
