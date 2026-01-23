# frozen_string_literal: true

# Intelligent mock for tmux commands used in agent executors.
#
# Provides realistic simulation of tmux session lifecycle:
# - Tracks active sessions with their state
# - Simulates session creation, existence checking, output capture, and termination
# - Supports configurable behaviors for testing error scenarios
#
# @example Basic usage in specs
#   include TmuxMockHelper
#
#   before { setup_tmux_mock }
#
#   it 'creates a session' do
#     expect(executor.execute(atom).success).to be true
#     expect(tmux_mock.sessions).to have_key(/eluent-/)
#   end
#
# @example Testing session failures
#   before do
#     setup_tmux_mock
#     tmux_mock.fail_session_creation!
#   end
#
# @example Testing session termination
#   before do
#     setup_tmux_mock
#     tmux_mock.auto_terminate_after(2) # Terminate after 2 existence checks
#   end
#
module TmuxMockHelper
  # Mock tmux server that tracks session state
  class TmuxMock
    attr_reader :sessions, :captured_outputs

    Session = Struct.new(:name, :command, :working_dir, :created_at, :terminated, :check_count, keyword_init: true)

    def initialize
      reset!
    end

    def reset!
      @sessions = {}
      @captured_outputs = {}
      @fail_creation = false
      @fail_has_session = false
      @auto_terminate_threshold = nil
      @simulate_unavailable = false
    end

    # Configuration methods

    def fail_session_creation!
      @fail_creation = true
    end

    def allow_session_creation!
      @fail_creation = false
    end

    def fail_has_session!
      @fail_has_session = true
    end

    def auto_terminate_after(check_count)
      @auto_terminate_threshold = check_count
    end

    def simulate_unavailable!
      @simulate_unavailable = true
    end

    def set_captured_output(session_name_or_pattern, output)
      @captured_outputs[session_name_or_pattern] = output
    end

    def unavailable?
      @simulate_unavailable
    end

    # Simulated tmux operations

    def new_session(name, working_dir, command)
      return false if @fail_creation

      @sessions[name] = Session.new(
        name: name,
        command: command,
        working_dir: working_dir,
        created_at: Time.now,
        terminated: false,
        check_count: 0
      )
      true
    end

    def has_session?(name)
      return false if @fail_has_session

      session = @sessions[name]
      return false unless session && !session.terminated

      session.check_count += 1

      if @auto_terminate_threshold && session.check_count >= @auto_terminate_threshold
        session.terminated = true
        return false
      end

      true
    end

    def kill_session(name)
      session = @sessions[name]
      return false unless session

      session.terminated = true
      true
    end

    def capture_pane(name)
      # Try exact match first
      return @captured_outputs[name] if @captured_outputs.key?(name)

      # Try pattern matching for Regexp keys
      @captured_outputs.each do |key, output|
        return output if key.is_a?(Regexp) && name.match?(key)
      end

      ''
    end

    # Query methods

    def session_names
      @sessions.keys
    end

    def active_sessions
      @sessions.reject { |_, s| s.terminated }
    end

    def terminated_sessions
      @sessions.select { |_, s| s.terminated }
    end

    def session_created?(name_pattern)
      if name_pattern.is_a?(Regexp)
        @sessions.keys.any? { |k| k.match?(name_pattern) }
      else
        @sessions.key?(name_pattern)
      end
    end
  end

  def tmux_mock
    @tmux_mock ||= TmuxMock.new
  end

  def setup_tmux_mock(target = nil)
    target = resolve_mock_target(target)
    mock = tmux_mock
    mock.reset!

    mock_tmux_availability(target, mock)
    mock_run_tmux(target, mock)
    mock_session_exists(target, mock)
    mock_destroy_session(target, mock)
    mock_capture_output(target, mock)

    mock
  end

  def resolve_mock_target(target)
    target ||= begin
      subject
    rescue StandardError
      nil
    end
    target ||= begin
      described_class
    rescue StandardError
      nil
    end
    return target if target

    raise ArgumentError, 'No target for tmux mock - pass target or ensure subject/described_class is defined'
  end

  def mock_tmux_availability(target, mock)
    return unless target.respond_to?(:tmux_available?, true)

    allow(target).to receive(:tmux_available?) { !mock.unavailable? }
  end

  def mock_run_tmux(target, mock)
    return unless target.respond_to?(:run_tmux, true)

    allow(target).to receive(:run_tmux) { |*args| handle_run_tmux(mock, *args) }
  end

  def mock_session_exists(target, mock)
    return unless target.respond_to?(:session_exists?, true)

    allow(target).to receive(:session_exists?) do |name|
      next false if name.to_s.empty?

      mock.has_session?(name)
    end
  end

  def mock_destroy_session(target, mock)
    return unless target.respond_to?(:destroy_session, true)

    allow(target).to receive(:destroy_session) do |name|
      next false if name.to_s.empty?

      mock.kill_session(name)
    end
  end

  def mock_capture_output(target, mock)
    return unless target.respond_to?(:capture_output, true)

    allow(target).to receive(:capture_output) do |name|
      next '' if name.to_s.empty?

      mock.capture_pane(name)
    end
  end

  private

  def handle_run_tmux(mock, *args)
    return false if mock.unavailable?

    case args.first
    when 'new-session'
      parse_new_session(mock, args)
    when 'has-session'
      parse_has_session(mock, args)
    when 'kill-session'
      parse_kill_session(mock, args)
    when 'capture-pane'
      parse_capture_pane(mock, args)
    else
      true # Unknown commands succeed by default
    end
  end

  def parse_new_session(mock, args)
    name = extract_flag_value(args, '-s')
    working_dir = extract_flag_value(args, '-c')
    # Command is the last positional argument after flags
    command = args.last unless args.last.start_with?('-')

    mock.new_session(name, working_dir, command)
  end

  def parse_has_session(mock, args)
    name = extract_flag_value(args, '-t')
    mock.has_session?(name)
  end

  def parse_kill_session(mock, args)
    name = extract_flag_value(args, '-t')
    mock.kill_session(name)
  end

  def parse_capture_pane(mock, args)
    name = extract_flag_value(args, '-t')
    mock.capture_pane(name)
  end

  def extract_flag_value(args, flag)
    idx = args.index(flag)
    idx ? args[idx + 1] : nil
  end
end

RSpec.configure do |config|
  config.include TmuxMockHelper, :tmux_mock
  config.include TmuxMockHelper, :external_mocks
end
