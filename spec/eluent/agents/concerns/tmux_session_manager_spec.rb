# frozen_string_literal: true

RSpec.describe Eluent::Agents::Concerns::TmuxSessionManager, :tmux_mock do
  # Create a test class that includes the concern
  let(:test_class) do
    Class.new do
      include Eluent::Agents::Concerns::TmuxSessionManager

      attr_reader :configuration

      def initialize(configuration)
        @configuration = configuration
      end

      # Expose private methods for testing
      public :start_session, :wait_for_session, :session_exists?, :capture_output,
             :destroy_session, :cleanup_session, :run_tmux, :resolve_working_directory,
             :write_context_file, :cleanup_context_file, :context_file_path,
             :build_context_content, :work_item_section, :instructions_section,
             :claude_code_command

      def session_error(message, session_name, operation)
        Eluent::Agents::SessionError.new(message, session_name: session_name, operation: operation)
      end
    end
  end

  let(:configuration) do
    Eluent::Agents::Configuration.new(
      skip_api_validation: true,
      working_directory: '/tmp/test-workdir',
      context_directory: '.eluent/agent-context'
    )
  end

  let(:manager) { test_class.new(configuration) }
  let(:atom) { Eluent::Models::Atom.new(id: 'TSK-123', title: 'Test Task', description: 'A test task') }

  before do
    allow(Dir).to receive(:exist?).with('/tmp/test-workdir').and_return(true)
    allow(Dir).to receive(:pwd).and_return('/current/dir')
  end

  describe '#resolve_working_directory' do
    it 'returns configured working directory when set' do
      expect(manager.resolve_working_directory).to eq('/tmp/test-workdir')
    end

    context 'when working_directory is nil' do
      let(:configuration) do
        Eluent::Agents::Configuration.new(skip_api_validation: true, working_directory: nil)
      end

      before { allow(Dir).to receive(:exist?).with('/current/dir').and_return(true) }

      it 'returns current working directory' do
        expect(manager.resolve_working_directory).to eq('/current/dir')
      end
    end

    context 'when directory does not exist' do
      before { allow(Dir).to receive(:exist?).with('/tmp/test-workdir').and_return(false) }

      it 'raises SessionError' do
        expect { manager.resolve_working_directory }.to raise_error(
          Eluent::Agents::SessionError,
          /Working directory does not exist/
        )
      end
    end
  end

  describe '#context_file_path' do
    it 'generates correct path' do
      path = manager.context_file_path(atom)

      expect(path).to eq('/tmp/test-workdir/.eluent/agent-context/TSK-123.md')
    end

    it 'sanitizes special characters in atom id' do
      special_atom = Eluent::Models::Atom.new(id: 'PRJ/TSK:123', title: 'Test')
      path = manager.context_file_path(special_atom)

      expect(path).to eq('/tmp/test-workdir/.eluent/agent-context/PRJ_TSK_123.md')
    end
  end

  describe '#build_context_content' do
    it 'combines system prompt, work item, and instructions' do
      content = manager.build_context_content(atom, 'System prompt here')

      expect(content).to include('System prompt here')
      expect(content).to include('# Work Item: TSK-123')
      expect(content).to include('**Title:** Test Task')
      expect(content).to include('A test task')
      expect(content).to include('el close TSK-123')
    end

    it 'handles nil system prompt' do
      content = manager.build_context_content(atom, nil)

      expect(content).to include('# Work Item: TSK-123')
      expect(content).not_to start_with("\n\n")
    end
  end

  describe '#work_item_section' do
    it 'includes all atom details' do
      section = manager.work_item_section(atom)

      expect(section).to include('# Work Item: TSK-123')
      expect(section).to include('**Title:** Test Task')
      expect(section).to include('**Type:**')
      expect(section).to include('**Priority:**')
      expect(section).to include('**Status:**')
      expect(section).to include('A test task')
    end

    it 'handles nil description' do
      atom_without_desc = Eluent::Models::Atom.new(id: 'TSK-456', title: 'No Desc')
      section = manager.work_item_section(atom_without_desc)

      expect(section).to include('_No description provided_')
    end
  end

  describe '#instructions_section' do
    it 'includes close command with atom id' do
      section = manager.instructions_section(atom)

      expect(section).to include('el close TSK-123')
      expect(section).to include('el comment add TSK-123')
    end

    it 'includes deferred status option' do
      section = manager.instructions_section(atom)

      expect(section).to include('el update TSK-123 --status deferred')
      expect(section).to include('may be revisited later')
    end

    it 'includes wont_do status option' do
      section = manager.instructions_section(atom)

      expect(section).to include('el update TSK-123 --status wont_do')
      expect(section).to include('should not be completed')
    end
  end

  describe '#write_context_file' do
    before do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
    end

    it 'creates directory and writes file' do
      manager.write_context_file(atom, 'prompt')

      expect(FileUtils).to have_received(:mkdir_p).with('/tmp/test-workdir/.eluent/agent-context')
      expect(File).to have_received(:write).with('/tmp/test-workdir/.eluent/agent-context/TSK-123.md', anything)
    end

    context 'when file write fails' do
      before do
        allow(File).to receive(:write).and_raise(Errno::EACCES.new('Permission denied'))
      end

      it 'raises SessionError' do
        expect { manager.write_context_file(atom, 'prompt') }.to raise_error(
          Eluent::Agents::SessionError,
          /Cannot write context file/
        )
      end
    end
  end

  describe '#cleanup_context_file' do
    it 'does nothing when no context file was written' do
      allow(File).to receive(:delete)

      manager.cleanup_context_file

      expect(File).not_to have_received(:delete)
    end

    it 'deletes context file when it exists' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      manager.write_context_file(atom, 'prompt')

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:delete)

      manager.cleanup_context_file

      expect(File).to have_received(:delete).with('/tmp/test-workdir/.eluent/agent-context/TSK-123.md')
    end

    it 'ignores errors during cleanup' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      manager.write_context_file(atom, 'prompt')

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:delete).and_raise(Errno::EACCES.new('Permission denied'))

      expect { manager.cleanup_context_file }.not_to raise_error
    end
  end

  describe '#session_exists?' do
    it 'returns false for empty session name' do
      expect(manager.session_exists?('')).to be false
      expect(manager.session_exists?(nil)).to be false
    end

    it 'checks tmux for session existence' do
      allow(manager).to receive(:system).with('tmux has-session -t test-session 2>/dev/null').and_return(true)

      expect(manager.session_exists?('test-session')).to be true
      expect(manager).to have_received(:system).with('tmux has-session -t test-session 2>/dev/null')
    end
  end

  describe '#destroy_session' do
    it 'returns false for empty session name' do
      expect(manager.destroy_session('')).to be false
      expect(manager.destroy_session(nil)).to be false
    end

    it 'kills tmux session' do
      allow(manager).to receive(:system).with('tmux kill-session -t test-session 2>/dev/null').and_return(true)

      expect(manager.destroy_session('test-session')).to be true
      expect(manager).to have_received(:system).with('tmux kill-session -t test-session 2>/dev/null')
    end
  end

  describe '#capture_output' do
    before { setup_tmux_mock(manager) }

    it 'returns empty string for empty session name' do
      expect(manager.capture_output('')).to eq('')
      expect(manager.capture_output(nil)).to eq('')
    end

    it 'captures tmux pane output for valid session' do
      tmux_mock.set_captured_output('test-session', "Some captured output\n")

      expect(manager.capture_output('test-session')).to eq("Some captured output\n")
    end

    it 'returns empty string when session has no output' do
      expect(manager.capture_output('empty-session')).to eq('')
    end
  end

  describe '#cleanup_session' do
    it 'always cleans up context file even with nil session name' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      manager.write_context_file(atom, 'prompt')

      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:delete)

      manager.cleanup_session(nil)

      expect(File).to have_received(:delete)
    end

    it 'destroys session and cleans up context file' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      manager.write_context_file(atom, 'prompt')

      allow(manager).to receive(:system).with('tmux kill-session -t test-session 2>/dev/null').and_return(true)
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:delete)

      manager.cleanup_session('test-session')

      expect(manager).to have_received(:system).with('tmux kill-session -t test-session 2>/dev/null')
      expect(File).to have_received(:delete)
    end
  end

  describe '#claude_code_command' do
    it 'returns the configured claude_code_path' do
      expect(manager.send(:claude_code_command)).to eq('claude')
    end

    context 'with custom claude_code_path' do
      let(:configuration) do
        Eluent::Agents::Configuration.new(
          skip_api_validation: true,
          working_directory: '/tmp/test-workdir',
          claude_code_path: '/custom/path/claude'
        )
      end

      it 'returns the custom path' do
        expect(manager.send(:claude_code_command)).to eq('/custom/path/claude')
      end
    end
  end
end
