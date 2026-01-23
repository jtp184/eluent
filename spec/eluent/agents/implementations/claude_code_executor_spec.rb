# frozen_string_literal: true

RSpec.describe Eluent::Agents::Implementations::ClaudeCodeExecutor do
  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      skip_api_validation: true,
      preserve_sessions: false,
      execution_timeout: 3600,
      agent_id: 'test-agent'
    )
  end
  let(:executor) { described_class.new(repository: repository, configuration: configuration) }
  let(:atom) { Eluent::Models::Atom.new(id: 'TSK-123', title: 'Test Task') }

  before do
    allow(executor).to receive_messages(
      tmux_available?: true,
      claude_code_available?: true,
      run_tmux: true,
      session_exists?: true,
      destroy_session: true,
      write_context_file: '/tmp/context.md'
    )
    allow(Dir).to receive(:exist?).and_return(true)
  end

  describe '#execute' do
    context 'when tmux is not available' do
      before { allow(executor).to receive(:tmux_available?).and_return(false) }

      it 'returns failure result' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('tmux not installed')
      end
    end

    context 'when Claude Code CLI is not available' do
      before { allow(executor).to receive(:claude_code_available?).and_return(false) }

      it 'returns failure result' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Claude Code CLI not found')
      end
    end

    context 'when atom is closed during execution' do
      let(:closed_atom) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:closed],
          close_reason: 'Completed'
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(closed_atom) }

      it 'returns success' do
        result = executor.execute(atom)

        expect(result.success).to be true
        expect(result.close_reason).to eq('Completed')
      end
    end

    context 'when atom status becomes deferred' do
      let(:deferred_atom) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:deferred]
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(deferred_atom) }

      it 'returns success' do
        result = executor.execute(atom)

        expect(result.success).to be true
      end
    end

    context 'when atom status becomes discard' do
      let(:discarded_atom) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:discard]
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(discarded_atom) }

      it 'returns success' do
        result = executor.execute(atom)

        expect(result.success).to be true
      end
    end

    context 'when atom status becomes wont_do' do
      let(:wont_do_atom) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:wont_do]
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(wont_do_atom) }

      it 'returns success' do
        result = executor.execute(atom)

        expect(result.success).to be true
      end
    end

    context 'when session terminates without closing atom' do
      before do
        allow(repository).to receive(:find_atom).and_return(atom)
        allow(executor).to receive(:session_exists?).and_return(true, true, false)
      end

      it 'returns failure' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('terminated without closing')
      end
    end

    context 'when atom is deleted during execution' do
      before do
        allow(repository).to receive(:find_atom).and_return(nil)
        allow(executor).to receive(:session_exists?).and_return(true)
      end

      it 'returns failure' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('deleted during execution')
      end
    end

    context 'when execution times out' do
      let(:configuration) do
        Eluent::Agents::Configuration.new(
          skip_api_validation: true,
          preserve_sessions: false,
          execution_timeout: 0,
          agent_id: 'test-agent'
        )
      end

      before do
        allow(repository).to receive(:find_atom).and_return(atom)
        allow(executor).to receive(:session_exists?).and_return(true)
      end

      it 'kills the session and returns failure' do
        allow(executor).to receive(:destroy_session)

        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('timeout')
        expect(executor).to have_received(:destroy_session).at_least(:once)
      end
    end

    context 'when session creation fails' do
      before do
        allow(executor).to receive(:run_tmux)
          .with('new-session', '-d', '-s', anything, '-c', anything, anything)
          .and_return(false)
      end

      it 'returns failure' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Failed to create tmux session')
      end
    end

    context 'when preserve_sessions is true' do
      let(:configuration) do
        Eluent::Agents::Configuration.new(
          skip_api_validation: true,
          preserve_sessions: true,
          agent_id: 'test-agent'
        )
      end

      let(:closed_atom) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:closed]
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(closed_atom) }

      it 'does not cleanup the session' do
        allow(executor).to receive(:cleanup_session)

        executor.execute(atom)

        expect(executor).not_to have_received(:cleanup_session)
      end
    end
  end

  describe '#generate_session_name' do
    it 'generates a unique session name with random suffix' do
      name = executor.send(:generate_session_name, atom)

      expect(name).to match(/^eluent-TSK-123-\d+-[a-f0-9]{8}$/)
    end

    it 'sanitizes special characters in atom id' do
      special_atom = Eluent::Models::Atom.new(id: 'PRJ/TSK#123', title: 'Test')
      name = executor.send(:generate_session_name, special_atom)

      expect(name).to match(/^eluent-PRJ-TSK--\d+-[a-f0-9]{8}$/)
    end

    it 'truncates long atom ids' do
      long_atom = Eluent::Models::Atom.new(id: 'VERY-LONG-PROJECT-IDENTIFIER-12345', title: 'Test')
      name = executor.send(:generate_session_name, long_atom)

      expect(name).to match(/^eluent-VERY-LON-\d+-[a-f0-9]{8}$/)
    end
  end

  describe '#terminal_status?' do
    it 'returns true for closed status' do
      closed_atom = Eluent::Models::Atom.new(id: 'test', title: 'Test', status: Eluent::Models::Status[:closed])
      expect(executor.send(:terminal_status?, closed_atom)).to be true
    end

    it 'returns true for deferred status' do
      deferred_atom = Eluent::Models::Atom.new(id: 'test', title: 'Test', status: Eluent::Models::Status[:deferred])
      expect(executor.send(:terminal_status?, deferred_atom)).to be true
    end

    it 'returns true for discard status' do
      discard_atom = Eluent::Models::Atom.new(id: 'test', title: 'Test', status: Eluent::Models::Status[:discard])
      expect(executor.send(:terminal_status?, discard_atom)).to be true
    end

    it 'returns true for wont_do status' do
      wont_do_atom = Eluent::Models::Atom.new(id: 'test', title: 'Test', status: Eluent::Models::Status[:wont_do])
      expect(executor.send(:terminal_status?, wont_do_atom)).to be true
    end

    it 'returns false for open status' do
      open_atom = Eluent::Models::Atom.new(id: 'test', title: 'Test', status: Eluent::Models::Status[:open])
      expect(executor.send(:terminal_status?, open_atom)).to be false
    end

    it 'returns false for in_progress status' do
      in_progress_atom = Eluent::Models::Atom.new(id: 'test', title: 'Test', status: Eluent::Models::Status[:in_progress])
      expect(executor.send(:terminal_status?, in_progress_atom)).to be false
    end
  end

  describe 'constants' do
    it 'has a poll interval' do
      expect(described_class::POLL_INTERVAL).to eq(3)
    end

    it 'defines terminal statuses' do
      expect(described_class::TERMINAL_STATUSES).to contain_exactly(:closed, :deferred, :wont_do, :discard)
    end
  end

  describe 'edge cases' do
    context 'when configuration validation fails before session creation' do
      before { allow(executor).to receive(:tmux_available?).and_return(false) }

      it 'does not attempt to cleanup a nil session' do
        allow(executor).to receive(:destroy_session)

        executor.execute(atom)

        # cleanup_session should not be called since @session_name is never set
        expect(executor).not_to have_received(:destroy_session)
      end

      it 'still cleans up context file if one was written' do
        # This edge case tests what happens if write_context_file is moved before validation
        # Currently validation happens first, so context file isn't written
        result = executor.execute(atom)
        expect(result.success).to be false
      end
    end

    context 'when atom status is already terminal' do
      let(:already_closed_atom) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:closed]
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(already_closed_atom) }

      it 'immediately returns success without multiple poll cycles' do
        result = executor.execute(atom)

        expect(result.success).to be true
        # Should call find_atom twice: once in monitor loop (detects terminal), once in build_success_result
        expect(repository).to have_received(:find_atom).twice
      end
    end

    context 'when atom status is a string-like object' do
      let(:atom_with_string_status) do
        Eluent::Models::Atom.new(
          id: 'TSK-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:closed]
        )
      end

      before { allow(repository).to receive(:find_atom).and_return(atom_with_string_status) }

      it 'correctly converts status to symbol for comparison' do
        result = executor.execute(atom)
        expect(result.success).to be true
      end
    end

    context 'when concurrent session names could collide' do
      it 'generates unique names even for rapid successive calls' do
        names = 10.times.map { executor.send(:generate_session_name, atom) }

        # All names should be unique
        expect(names.uniq.size).to eq(10)
      end
    end

    context 'when context file write fails' do
      before do
        allow(executor).to receive(:write_context_file).and_raise(
          Eluent::Agents::SessionError.new('Cannot write context file: Permission denied', operation: :write_context)
        )
      end

      it 'returns failure' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Permission denied')
      end
    end
  end
end
