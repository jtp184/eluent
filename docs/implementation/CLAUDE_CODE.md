# Claude Code Executor

## Overview

The `ClaudeCodeExecutor` runs Claude Code CLI inside tmux sessions to perform work on Eluent atoms. Unlike API-based executors that make HTTP calls, this executor spawns an external process and monitors it until the atom reaches a terminal state.

```
ExecutionLoop
    │
    ▼
ClaudeCodeExecutor < AgentExecutor
    ├── includes TmuxSessionManager (concern)
    └── monitors atom status via repository polling
```

**Completion Signal:** Claude Code runs `el close {id}` to mark work done. The executor detects this by polling `repository.find_atom(id)` and checking for terminal statuses: `closed`, `deferred`, `wont_do`, or `discard`.

## Implementation

### 1. `lib/eluent/agents/implementations/claude_code_executor.rb`

```ruby
# frozen_string_literal: true

require 'securerandom'

module Eluent
  module Agents
    module Implementations
      class ClaudeCodeExecutor < AgentExecutor
        include Concerns::TmuxSessionManager

        POLL_INTERVAL = 3
        TERMINAL_STATUSES = %i[closed deferred wont_do discard].freeze

        def execute(atom, system_prompt: nil)
          @start_time = monotonic_now
          validate_configuration!

          session_name = generate_session_name(atom)
          start_session(session_name, atom, system_prompt)
          monitor_until_complete(session_name, atom)

          build_success_result(atom)
        rescue SessionError, TimeoutError => e
          destroy_session(session_name) if e.is_a?(TimeoutError)
          ExecutionResult.failure(error: e.message, atom: atom)
        ensure
          cleanup_session(session_name) unless configuration.preserve_sessions
        end

        private

        def monitor_until_complete(session_name, atom)
          loop do
            check_execution_timeout!

            refreshed = repository.find_atom(atom.id)
            raise session_error("Atom #{atom.id} deleted during execution", session_name, :monitor) unless refreshed
            return if terminal_status?(refreshed)

            unless session_exists?(session_name)
              raise session_error("Session terminated without closing atom", session_name, :monitor)
            end

            sleep POLL_INTERVAL
          end
        end

        def terminal_status?(atom)
          TERMINAL_STATUSES.include?(atom.status.to_sym)
        end

        def check_execution_timeout!
          elapsed = monotonic_now - @start_time
          return unless elapsed > configuration.execution_timeout

          raise TimeoutError.new(
            "Execution timeout (#{configuration.execution_timeout}s) exceeded",
            timeout_seconds: elapsed
          )
        end

        def validate_configuration!
          raise ConfigurationError.new("tmux not installed or not in PATH", field: :tmux) unless tmux_available?
          raise ConfigurationError.new("Claude Code CLI not found", field: :claude_code_path) unless claude_code_available?
        end

        def tmux_available?
          system("command -v tmux > /dev/null 2>&1")
        end

        def claude_code_available?
          path = configuration.claude_code_path
          path.include?("/") ? File.executable?(path) : system("command -v #{path} > /dev/null 2>&1")
        end

        def generate_session_name(atom)
          safe_id = atom.id.to_s.gsub(/[^a-zA-Z0-9]/, "-")[0..7]
          "eluent-#{safe_id}-#{Time.now.to_i}-#{SecureRandom.hex(4)}"
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def session_error(message, session_name, operation)
          SessionError.new(message, session_name: session_name, operation: operation)
        end
      end
    end
  end
end
```

### 2. `lib/eluent/agents/concerns/tmux_session_manager.rb`

```ruby
# frozen_string_literal: true

require "shellwords"
require "fileutils"

module Eluent
  module Agents
    module Concerns
      module TmuxSessionManager
        SESSION_START_TIMEOUT = 5

        private

        # Session lifecycle

        def start_session(name, atom, prompt)
          context_file = write_context_file(atom, prompt)
          working_dir = resolve_working_directory
          cmd = "#{Shellwords.escape(claude_code_command)} -p #{Shellwords.escape(context_file)}"

          run_tmux("new-session", "-d", "-s", name, "-c", working_dir, cmd) or
            raise session_error("Failed to create tmux session", name, :create)

          wait_for_session(name) or
            raise session_error("Session created but not accessible", name, :create)
        end

        def wait_for_session(name, timeout: SESSION_START_TIMEOUT)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            return true if session_exists?(name)
            return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.1
          end
        end

        def session_exists?(name)
          return false if name.to_s.empty?
          system("tmux has-session -t #{Shellwords.escape(name)} 2>/dev/null")
        end

        def capture_output(name)
          return "" if name.to_s.empty?
          `tmux capture-pane -p -t #{Shellwords.escape(name)} -S -1000`
        end

        def destroy_session(name)
          return false if name.to_s.empty?
          system("tmux kill-session -t #{Shellwords.escape(name)} 2>/dev/null")
        end

        def cleanup_session(name)
          return if name.to_s.empty?
          destroy_session(name)
          cleanup_context_file
        end

        def run_tmux(*args)
          system('tmux', *args)
        end

        def resolve_working_directory
          dir = configuration.working_directory || Dir.pwd
          raise session_error("Working directory does not exist: #{dir}", nil, :validate_directory) unless Dir.exist?(dir)
          dir
        end

        # Context file management

        def write_context_file(atom, system_prompt)
          @context_file_path = context_file_path(atom)
          FileUtils.mkdir_p(File.dirname(@context_file_path))
          File.write(@context_file_path, build_context_content(atom, system_prompt))
          @context_file_path
        rescue Errno::EACCES, Errno::EROFS => e
          raise session_error("Cannot write context file: #{e.message}", nil, :write_context)
        end

        def cleanup_context_file
          return unless @context_file_path && File.exist?(@context_file_path)
          File.delete(@context_file_path)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EROFS
          # Ignore cleanup failures
        end

        def context_file_path(atom)
          dir = configuration.context_directory
          safe_id = atom.id.to_s.gsub(%r{[/\\:*?"<>|]}, "_")
          File.join(resolve_working_directory, dir, "#{safe_id}.md")
        end

        def build_context_content(atom, system_prompt)
          [
            system_prompt,
            work_item_section(atom),
            instructions_section(atom)
          ].compact.join("\n\n")
        end

        def work_item_section(atom)
          <<~MARKDOWN
            # Work Item: #{atom.id}

            **Title:** #{atom.title}
            **Type:** #{atom.issue_type}
            **Priority:** #{atom.priority}
            **Status:** #{atom.status}

            ## Description

            #{atom.description || "_No description provided_"}
          MARKDOWN
        end

        def instructions_section(atom)
          safe_id = Shellwords.escape(atom.id)
          <<~MARKDOWN
            ## Instructions

            Complete this task. When finished, run:

            ```bash
            el close #{safe_id} --reason "Brief summary of work completed"
            ```

            If the task cannot be completed now but may be revisited later:

            ```bash
            el update #{safe_id} --status deferred
            el comment add #{safe_id} "Reason this task is deferred..."
            ```

            If the task should not be completed at all:

            ```bash
            el update #{safe_id} --status wont_do
            el comment add #{safe_id} "Reason this task will not be done..."
            ```
          MARKDOWN
        end
      end
    end
  end
end
```

### 3. Configuration Extensions

Add to `lib/eluent/agents/configuration.rb`:

```ruby
DEFAULT_CLAUDE_CODE_PATH = "claude"
DEFAULT_CONTEXT_DIRECTORY = ".eluent/agent-context"

def initialize(
  # ... existing parameters ...
  claude_code_path: DEFAULT_CLAUDE_CODE_PATH,
  working_directory: nil,
  preserve_sessions: false,
  context_directory: DEFAULT_CONTEXT_DIRECTORY
)
  # ... existing assignments ...
  @claude_code_path = claude_code_path
  @working_directory = working_directory
  @preserve_sessions = preserve_sessions
  @context_directory = context_directory
end

attr_reader :claude_code_path, :working_directory, :preserve_sessions, :context_directory
```

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `claude_code_path` | `"claude"` | Path to Claude Code binary |
| `working_directory` | `nil` (uses `Dir.pwd`) | Working directory for tmux sessions |
| `preserve_sessions` | `false` | Keep tmux sessions after completion |
| `context_directory` | `".eluent/agent-context"` | Where to write context files |

### 4. Error Class

Add to `lib/eluent/agents/errors.rb`:

```ruby
class SessionError < AgentError
  attr_reader :session_name, :operation

  def initialize(message, session_name: nil, operation: nil)
    super(message)
    @session_name = session_name
    @operation = operation
  end
end
```

## Execution Flow

```
ExecutionLoop                          ClaudeCodeExecutor
     │                                        │
     ├─ claims atom (sets :in_progress)       │
     │                                        │
     └─ calls execute(atom) ─────────────────►│
                                              ├─ validates configuration
                                              ├─ writes context file
                                              ├─ creates tmux session
                                              ├─ sends `claude -p {file}`
                                              │
                                              │  ┌─────── poll loop ───────┐
                                              │  │ check timeout           │
                                              │  │ reload atom from repo   │
                                              │  │ if terminal? → return   │
                                              │  │ if session dead → error │
                                              │  │ sleep 3s                │
                                              │  └─────────────────────────┘
                                              │
                                              └─ cleanup session and context file
```

## CLI Commands for Claude Code

| Command | Purpose |
|---------|---------|
| `el close ID --reason "..."` | Signal successful completion |
| `el update ID --status deferred` | Signal task deferred for later |
| `el update ID --status wont_do` | Signal task will not be completed |
| `el update ID --status discard` | Signal task should be abandoned |
| `el comment add ID "..."` | Add progress notes |
| `el update ID --status blocked` | Report blockers (non-terminal) |
| `el list --robot` | List work items (JSON) |
| `el show ID --robot` | View item details (JSON) |

## Error Handling

| Scenario | Result |
|----------|--------|
| tmux not installed | `ConfigurationError` |
| Claude Code not found | `ConfigurationError` |
| Working directory missing | `SessionError` |
| Context file write fails | `SessionError` |
| Session creation fails | `SessionError` |
| Session dies without closing atom | `ExecutionResult.failure` |
| Atom deleted during execution | `ExecutionResult.failure` |
| Execution timeout | Session killed, `ExecutionResult.failure` |

## Testing

### Unit Tests

```ruby
RSpec.describe Eluent::Agents::Implementations::ClaudeCodeExecutor do
  let(:config) { build_configuration(preserve_sessions: false) }
  let(:repo) { instance_double(Repository) }
  let(:executor) { described_class.new(repository: repo, configuration: config) }
  let(:atom) { build_atom(id: "TSK-123", status: :open) }

  before do
    allow(executor).to receive(:run_tmux).and_return(true)
    allow(executor).to receive(:session_exists?).and_return(true)
  end

  describe "#execute" do
    context "when atom is closed during execution" do
      let(:closed_atom) { build_atom(id: "TSK-123", status: :closed) }

      before { allow(repo).to receive(:find_atom).and_return(closed_atom) }

      it "returns success" do
        result = executor.execute(atom)
        expect(result).to be_success
      end
    end

    context "when session terminates without closing atom" do
      before do
        allow(repo).to receive(:find_atom).and_return(atom)
        allow(executor).to receive(:session_exists?).and_return(false)
      end

      it "returns failure" do
        result = executor.execute(atom)
        expect(result).not_to be_success
        expect(result.error).to include("terminated without closing")
      end
    end

    context "when atom is deleted during execution" do
      before { allow(repo).to receive(:find_atom).and_return(nil) }

      it "returns failure" do
        result = executor.execute(atom)
        expect(result).not_to be_success
        expect(result.error).to include("deleted during execution")
      end
    end

    context "when execution times out" do
      before do
        allow(config).to receive(:execution_timeout).and_return(0)
        allow(repo).to receive(:find_atom).and_return(atom)
      end

      it "kills the session and returns failure" do
        expect(executor).to receive(:destroy_session)
        result = executor.execute(atom)
        expect(result).not_to be_success
        expect(result.error).to include("timeout")
      end
    end
  end
end
```

### Integration Tests

```ruby
RSpec.describe "ClaudeCodeExecutor integration", :integration do
  before(:all) do
    skip "tmux required" unless system("command -v tmux > /dev/null")
  end

  it "detects when session is killed externally" do
    # Start executor, then kill session via `tmux kill-session`
    # Verify failure is detected
  end

  it "handles concurrent executions with unique session names" do
    # Launch multiple executors in parallel
    # Verify no session name collisions
  end
end
```

### Manual Verification

```bash
# Create test atom
el create --title "Test task" --type task

# Run executor and observe
tmux ls | grep eluent           # Verify session created
tmux attach -t eluent-...       # Watch execution

# Test edge cases
tmux kill-session -t eluent-... # Should trigger failure
ls .eluent/agent-context/       # Verify cleanup
```

## Implementation Order

1. `SessionError` in `errors.rb`
2. Configuration extensions
3. `TmuxSessionManager` concern
4. `ClaudeCodeExecutor` class
5. Unit tests
6. Integration tests

## API Key Validation

The existing `Configuration#validate!` requires an API key, but `ClaudeCodeExecutor` doesn't need one. Add a `skip_api_validation` parameter to Configuration:

```ruby
def initialize(
  # ...
  skip_api_validation: false
)
  @skip_api_validation = skip_api_validation
end

def validate!
  unless skip_api_validation || any_provider_configured?
    raise ConfigurationError.new('No API provider configured', field: :api_keys)
  end
  # remaining validations...
end
```

## Known Limitations

| Limitation | Mitigation |
|------------|------------|
| No graceful shutdown | Could send SIGTERM before kill |
| No heartbeat mechanism | Could detect activity via `capture_output` diff |
| Single executor per repository | Document as unsupported configuration |
| Context file visible to agent | Acceptable; agent needs the information |
