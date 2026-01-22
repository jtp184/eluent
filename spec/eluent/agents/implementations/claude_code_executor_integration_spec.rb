# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll -- integration spec pattern
RSpec.describe 'ClaudeCodeExecutor integration', :integration do
  before(:all) do
    skip 'tmux required' unless system('command -v tmux > /dev/null 2>&1')
  end

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
    # Cleanup any test sessions that might be left behind
    system('tmux kill-session -t eluent-INT-TEST 2>/dev/null')
  end

  describe 'session lifecycle' do
    it 'creates and cleans up tmux sessions' do
      allow(executor).to receive(:claude_code_available?).and_return(true)
      allow(executor).to receive(:claude_code_command).and_return('sleep 60')

      closed_atom = Eluent::Models::Atom.new(
        id: 'INT-TEST-123',
        title: 'Integration Test Task',
        status: Eluent::Models::Status[:closed]
      )

      allow(repository).to receive(:find_atom).and_return(closed_atom)

      result = executor.execute(atom)

      expect(result.success).to be true

      # Session should be cleaned up
      session_pattern = 'eluent-INT-TEST'
      sessions = `tmux list-sessions 2>/dev/null`.lines.grep(/#{Regexp.escape(session_pattern)}/)
      expect(sessions).to be_empty
    end

    it 'handles concurrent executions with unique session names' do
      skip 'Claude Code CLI required' unless system('command -v claude > /dev/null 2>&1')

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
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll
