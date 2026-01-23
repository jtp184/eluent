# frozen_string_literal: true

# Intelligent mock for Claude Code CLI used in agent executors.
#
# Simulates Claude Code CLI availability and execution behavior:
# - Mocks executable path detection (both PATH lookup and absolute paths)
# - Tracks invocation attempts for test assertions
# - Supports configurable availability states
#
# @example Basic usage in specs
#   include ClaudeMockHelper
#
#   before { setup_claude_mock }
#
#   it 'executes when claude is available' do
#     expect(executor.execute(atom).success).to be true
#   end
#
# @example Testing unavailability
#   before do
#     setup_claude_mock
#     claude_mock.simulate_unavailable!
#   end
#
#   it 'fails when claude is not available' do
#     result = executor.execute(atom)
#     expect(result.success).to be false
#     expect(result.error).to include('Claude Code CLI not found')
#   end
#
# @example Tracking invocations
#   it 'invokes claude with context file' do
#     executor.execute(atom, system_prompt: 'Test prompt')
#     expect(claude_mock.invocation_count).to eq(1)
#     expect(claude_mock.last_context_file).to match(/\.md$/)
#   end
#
module ClaudeMockHelper
  # Mock Claude Code CLI that tracks invocations and availability
  class ClaudeMock
    attr_reader :invocations, :configured_path

    Invocation = Struct.new(:context_file, :timestamp, keyword_init: true)

    def initialize
      reset!
    end

    def reset!
      @invocations = []
      @available = true
      @configured_path = 'claude'
      @executable_paths = {}
    end

    # Configuration methods

    def simulate_unavailable!
      @available = false
    end

    def simulate_available!
      @available = true
    end

    def available?
      @available
    end

    def set_path(path)
      @configured_path = path
    end

    def register_executable(path)
      @executable_paths[path] = true
    end

    def unregister_executable(path)
      @executable_paths.delete(path)
    end

    # Simulated operations

    def record_invocation(context_file)
      @invocations << Invocation.new(
        context_file: context_file,
        timestamp: Time.now
      )
    end

    def executable?(path)
      return false unless @available

      if path.include?('/')
        @executable_paths[path] || (File.exist?(path) && File.executable?(path))
      else
        # Simulate PATH lookup - if available, assume it's in PATH
        @available
      end
    end

    def command_exists?(command)
      return false unless @available

      # For non-path commands, return true if mock is available
      command == @configured_path || @executable_paths.key?(command)
    end

    # Query methods

    def invocation_count
      @invocations.size
    end

    def last_invocation
      @invocations.last
    end

    def last_context_file
      last_invocation&.context_file
    end

    def invoked?
      @invocations.any?
    end

    def invocations_with_context(pattern)
      @invocations.select do |inv|
        case pattern
        when Regexp then inv.context_file&.match?(pattern)
        when String then inv.context_file&.include?(pattern)
        else false
        end
      end
    end
  end

  def claude_mock
    @claude_mock ||= ClaudeMock.new
  end

  def setup_claude_mock(target = nil)
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
    unless target
      raise ArgumentError,
            'No target for claude mock - pass target or ensure subject/described_class is defined'
    end

    mock = claude_mock
    mock.reset!

    # Mock claude_code_available? method
    if target.respond_to?(:claude_code_available?, true)
      allow(target).to receive(:claude_code_available?) { mock.available? }
    end

    # Mock claude_code_command to return configured path
    if target.respond_to?(:claude_code_command, true)
      allow(target).to receive(:claude_code_command) { mock.configured_path }
    end

    mock
  end

  # Combined setup for both tmux and claude mocks
  def setup_external_command_mocks(target = nil)
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

    tmux = setup_tmux_mock(target) if respond_to?(:setup_tmux_mock)
    claude = setup_claude_mock(target)

    { tmux: tmux, claude: claude }.compact
  end
end

RSpec.configure do |config|
  config.include ClaudeMockHelper, :claude_mock
  config.include ClaudeMockHelper, :external_mocks
end
