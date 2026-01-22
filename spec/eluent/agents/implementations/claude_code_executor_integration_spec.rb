# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass -- integration spec pattern
RSpec.describe 'ClaudeCodeExecutor integration', :integration do
  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:working_dir) { Dir.mktmpdir('eluent-test') }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      skip_api_validation: true,
      preserve_sessions: false,
      working_directory: working_dir,
      context_directory: '.eluent/agent-context',
      execution_timeout: 10
    )
  end
  let(:executor) { Eluent::Agents::Implementations::ClaudeCodeExecutor.new(repository: repository, configuration: configuration) }
  let(:atom) { Eluent::Models::Atom.new(id: 'INT-TEST-123', title: 'Integration Test Task') }

  after do
    FileUtils.rm_rf(working_dir) if working_dir && Dir.exist?(working_dir)
  end

  # Tests using intelligent mocks (no real tmux/claude required)
  describe 'with mocked external commands', :external_mocks do
    before do
      setup_tmux_mock(executor)
      setup_claude_mock(executor)
    end

    let(:closed_atom) do
      Eluent::Models::Atom.new(id: 'INT-TEST-123', title: 'Integration Test Task', status: Eluent::Models::Status[:closed])
    end

    context 'when session is created successfully' do
      before { allow(repository).to receive(:find_atom).and_return(closed_atom) }

      it 'tracks session creation with correct parameters' do
        result = executor.execute(atom, system_prompt: 'Test prompt')

        expect(result.success).to be true
        expect(tmux_mock.session_created?(/eluent-INT-TEST/)).to be true
      end

      it 'creates session with working directory' do
        executor.execute(atom)

        session = tmux_mock.active_sessions.values.first || tmux_mock.terminated_sessions.values.first
        expect(session.working_dir).to eq(working_dir)
      end

      it 'cleans up session after completion' do
        executor.execute(atom)

        expect(tmux_mock.terminated_sessions.size).to eq(1)
      end
    end

    context 'when session auto-terminates before atom closes' do
      before do
        allow(repository).to receive(:find_atom).and_return(atom) # Non-terminal status
        tmux_mock.auto_terminate_after(2) # Terminate after 2 existence checks
      end

      it 'detects premature termination' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('terminated without closing')
      end
    end

    context 'when claude is unavailable' do
      before { claude_mock.simulate_unavailable! }

      it 'fails with appropriate error' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Claude Code CLI not found')
      end
    end

    context 'when tmux session creation fails' do
      before do
        tmux_mock.fail_session_creation!
        allow(repository).to receive(:find_atom).and_return(closed_atom)
      end

      it 'fails with session creation error' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Failed to create tmux session')
      end
    end

    context 'when capturing output' do
      before do
        allow(repository).to receive(:find_atom).and_return(closed_atom)
        tmux_mock.set_captured_output(/eluent-INT-TEST/, "Task completed successfully\nClaude signing off")
      end

      it 'captures session output via mock' do
        executor.execute(atom)

        session_name = tmux_mock.session_names.first
        expect(tmux_mock.capture_pane(session_name)).to include('Task completed')
      end
    end
  end

  describe 'session lifecycle', :external_mocks do
    before do
      setup_tmux_mock(executor)
      setup_claude_mock(executor)
    end

    it 'creates and cleans up tmux sessions' do
      closed_atom = Eluent::Models::Atom.new(
        id: 'INT-TEST-123',
        title: 'Integration Test Task',
        status: Eluent::Models::Status[:closed]
      )

      allow(repository).to receive(:find_atom).and_return(closed_atom)

      result = executor.execute(atom)

      expect(result.success).to be true

      # Session should be cleaned up (terminated via mock)
      expect(tmux_mock.terminated_sessions).not_to be_empty
    end

    it 'handles concurrent executions with unique session names' do
      atom1 = Eluent::Models::Atom.new(id: 'CONC-1', title: 'Task 1')
      atom2 = Eluent::Models::Atom.new(id: 'CONC-2', title: 'Task 2')

      name1 = executor.send(:generate_session_name, atom1)
      name2 = executor.send(:generate_session_name, atom2)

      # Names should be unique even for atoms created at same time
      # (timestamp granularity might cause issues, but the atom ID portion differs)
      expect(name1).not_to eq(name2)
    end
  end

  describe 'context file management' do
    let(:context_file) { File.join(working_dir, '.eluent/agent-context', 'INT-TEST-123.md') }
    let(:closed_atom) do
      Eluent::Models::Atom.new(id: 'INT-TEST-123', title: 'Integration Test Task', status: Eluent::Models::Status[:closed])
    end

    before { allow(repository).to receive(:find_atom).and_return(closed_atom) }

    it 'writes context files with correct content' do
      preserve_config = Eluent::Agents::Configuration.new(
        skip_api_validation: true,
        preserve_sessions: true,
        working_directory: working_dir,
        context_directory: '.eluent/agent-context',
        execution_timeout: 10
      )
      preserve_executor = Eluent::Agents::Implementations::ClaudeCodeExecutor.new(
        repository: repository,
        configuration: preserve_config
      )

      allow(preserve_executor).to receive_messages(run_tmux: true, session_exists?: true, claude_code_available?: true)
      preserve_executor.execute(atom, system_prompt: 'Custom system prompt')

      expect(File.exist?(context_file)).to be true
      expect(File.read(context_file)).to include('Custom system prompt', 'INT-TEST-123', 'Integration Test Task')
    ensure
      FileUtils.rm_f(context_file)
    end

    it 'cleans up context files after execution' do
      allow(executor).to receive_messages(run_tmux: true, session_exists?: true, claude_code_available?: true)
      executor.execute(atom)

      expect(File.exist?(context_file)).to be false
    end
  end

  describe 'error scenarios' do
    it 'handles working directory that does not exist' do
      bad_config = Eluent::Agents::Configuration.new(
        skip_api_validation: true,
        working_directory: '/nonexistent/directory'
      )
      bad_executor = Eluent::Agents::Implementations::ClaudeCodeExecutor.new(
        repository: repository,
        configuration: bad_config
      )

      allow(bad_executor).to receive_messages(tmux_available?: true, claude_code_available?: true)

      result = bad_executor.execute(atom)

      expect(result.success).to be false
      expect(result.error).to include('Working directory does not exist')
    end

    it 'handles session creation failure' do
      allow(executor).to receive(:claude_code_available?).and_return(true)
      allow(executor).to receive(:run_tmux)
        .with('new-session', anything, anything, anything, anything, anything, anything)
        .and_return(false)

      result = executor.execute(atom)

      expect(result.success).to be false
      expect(result.error).to include('Failed to create tmux session')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
