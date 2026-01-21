# frozen_string_literal: true

RSpec.describe Eluent::Daemon::CommandRouter do
  let(:router) { described_class.new }
  let(:test_atom_id) { 'test-01ARZ3NDEKTSV4RRFFQ69G5FAV' }

  # Shared FakeFS setup for filesystem-dependent specs
  shared_context 'with fake filesystem' do
    around do |example|
      FakeFS.activate!
      FakeFS::FileSystem.clear
      example.run
    ensure
      FakeFS.deactivate!
    end
  end

  def setup_repo(path, config_yaml: "repo_name: test\n", atoms: [])
    FileUtils.mkdir_p("#{path}/.eluent")
    FileUtils.mkdir_p("#{path}/.git")

    lines = ['{"_type":"header","repo_name":"test"}']
    atoms.each { |atom| lines << JSON.generate(atom) }

    File.write("#{path}/.eluent/data.jsonl", "#{lines.join("\n")}\n")
    File.write("#{path}/.eluent/config.yaml", config_yaml)
  end

  def open_atom(id: test_atom_id, title: 'Test atom')
    {
      '_type' => 'atom',
      'id' => id,
      'title' => title,
      'status' => 'open',
      'issue_type' => 'task',
      'priority' => 2,
      'labels' => [],
      'created_at' => '2025-01-15T10:00:00Z',
      'updated_at' => '2025-01-15T10:00:00Z',
      'metadata' => {}
    }
  end

  def closed_atom(id: test_atom_id, title: 'Closed atom')
    open_atom(id: id, title: title).merge('status' => 'closed', 'close_reason' => 'done')
  end

  def blocked_atom(id: test_atom_id, title: 'Blocked atom')
    open_atom(id: id, title: title).merge('status' => 'blocked')
  end

  def discarded_atom(id: test_atom_id, title: 'Discarded atom')
    open_atom(id: id, title: title).merge('status' => 'discard')
  end

  describe 'COMMANDS' do
    it 'includes expected commands' do
      expect(described_class::COMMANDS).to include('ping', 'list', 'show', 'create', 'update', 'close', 'sync')
    end

    it 'includes ledger-related commands' do
      expect(described_class::COMMANDS).to include('claim', 'ledger_sync')
    end
  end

  describe '#route' do
    describe 'ping command' do
      let(:request) { { id: 'req-123', cmd: 'ping', args: {} } }

      it 'returns success with pong' do
        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:id]).to eq('req-123')
        expect(response[:data][:pong]).to be true
      end

      it 'includes timestamp' do
        response = router.route(request)
        expect(response[:data][:time]).to match(/\d{4}-\d{2}-\d{2}T/)
      end
    end

    describe 'unknown command' do
      let(:request) { { id: 'req-123', cmd: 'unknown', args: {} } }

      it 'returns error' do
        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('UNKNOWN_COMMAND')
      end
    end

    describe 'command without repo_path' do
      let(:request) { { id: 'req-123', cmd: 'list', args: {} } }

      it 'returns repo not found error' do
        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('REPO_NOT_FOUND')
      end
    end
  end

  describe 'repository caching', :filesystem do
    include_context 'with fake filesystem'

    it 'caches repositories by path' do
      setup_repo('/project')

      router.route({ id: 'req-1', cmd: 'list', args: { repo_path: '/project' } })
      router.route({ id: 'req-2', cmd: 'list', args: { repo_path: '/project' } })

      expect(router.send(:repo_cache).keys).to eq(['/project'])
    end
  end

  describe 'claim command', :filesystem do
    include_context 'with fake filesystem'

    context 'without ledger sync configured' do
      before { setup_repo('/project', atoms: [open_atom]) }

      it 'claims atom locally' do
        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'test-agent' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:data][:atom_id]).to eq(test_atom_id)
        expect(response[:data][:agent_id]).to eq('test-agent')
        expect(response[:data][:offline]).to be true
      end

      it 'returns error for non-existent atom' do
        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: 'nonexistent', agent_id: 'test-agent' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('NOT_FOUND')
      end

      it 'uses default agent_id when not provided' do
        allow(Socket).to receive(:gethostname).and_return('test-host')

        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id }
        }

        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:data][:agent_id]).to eq('test-host')
      end

      it 'uses default agent_id when provided empty string' do
        allow(Socket).to receive(:gethostname).and_return('default-host')

        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: '   ' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:data][:agent_id]).to eq('default-host')
      end
    end

    context 'with already claimed atom' do
      before do
        setup_repo('/project', atoms: [open_atom])
        router.route({
                       id: 'req-1',
                       cmd: 'claim',
                       args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'agent-1' }
                     })
      end

      it 'returns conflict for different agent without force' do
        request = {
          id: 'req-2',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'agent-2' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('CLAIM_CONFLICT')
        expect(response[:error][:message]).to include('agent-1')
      end

      it 'allows force claim from different agent' do
        request = {
          id: 'req-2',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'agent-2', force: true }
        }

        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:data][:agent_id]).to eq('agent-2')
      end

      it 'allows same agent to re-claim' do
        request = {
          id: 'req-2',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'agent-1' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('ok')
      end
    end

    context 'with closed atom' do
      before { setup_repo('/project', atoms: [closed_atom]) }

      it 'returns error for closed atom' do
        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'test-agent' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('INVALID_STATE')
        expect(response[:error][:message]).to include('closed')
      end
    end

    context 'with blocked atom' do
      before { setup_repo('/project', atoms: [blocked_atom]) }

      it 'returns error for blocked atom' do
        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'test-agent' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('INVALID_STATE')
        expect(response[:error][:message]).to include('blocked')
      end
    end

    context 'with discarded atom' do
      before { setup_repo('/project', atoms: [discarded_atom]) }

      it 'returns error for discarded atom' do
        request = {
          id: 'req-123',
          cmd: 'claim',
          args: { repo_path: '/project', atom_id: test_atom_id, agent_id: 'test-agent' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('INVALID_STATE')
        expect(response[:error][:message]).to include('discard')
      end
    end
  end

  describe 'ledger_sync command', :filesystem do
    include_context 'with fake filesystem'

    let(:ledger_config) do
      <<~YAML
        repo_name: test
        sync:
          ledger_branch: eluent-sync
          claim_retries: 3
      YAML
    end

    describe 'status action' do
      it 'returns status without ledger configured' do
        setup_repo('/project')

        request = {
          id: 'req-123',
          cmd: 'ledger_sync',
          args: { repo_path: '/project', action: 'status' }
        }

        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:data][:action]).to eq('status')
        expect(response[:data][:configured]).to be false
        expect(response[:data][:ledger_branch]).to be_nil
        expect(response[:data][:available]).to be false
      end

      # NOTE: Testing with ledger configured requires mocking git operations
      # because FakeFS doesn't support running actual git commands.
      # Integration tests cover the full ledger sync workflow.
    end

    describe 'missing action' do
      before { setup_repo('/project') }

      it 'returns error when action is nil' do
        response = router.route({
                                  id: 'req-123',
                                  cmd: 'ledger_sync',
                                  args: { repo_path: '/project' }
                                })

        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('INVALID_REQUEST')
        expect(response[:error][:message]).to include('requires an action')
      end

      it 'returns error when action is empty string' do
        response = router.route({
                                  id: 'req-123',
                                  cmd: 'ledger_sync',
                                  args: { repo_path: '/project', action: '  ' }
                                })

        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('INVALID_REQUEST')
        expect(response[:error][:message]).to include('requires an action')
      end
    end

    describe 'unknown action' do
      it 'returns error for unknown action' do
        setup_repo('/project')

        response = router.route({
                                  id: 'req-123',
                                  cmd: 'ledger_sync',
                                  args: { repo_path: '/project', action: 'unknown_action' }
                                })

        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('INVALID_REQUEST')
        expect(response[:error][:message]).to include('unknown_action')
      end
    end

    describe 'actions requiring ledger configuration' do
      before { setup_repo('/project') }

      %w[setup pull push teardown reconcile].each do |action|
        it "#{action} returns error when ledger not configured" do
          response = router.route({
                                    id: 'req-123',
                                    cmd: 'ledger_sync',
                                    args: { repo_path: '/project', action: action }
                                  })

          expect(response[:status]).to eq('error')
          expect(response[:error][:code]).to eq('LEDGER_NOT_CONFIGURED')
        end
      end

      # NOTE: Testing with ledger configured requires mocking git operations.
      # Integration tests cover the full ledger sync workflow.
    end
  end

  describe 'ledger syncer caching', :filesystem do
    include_context 'with fake filesystem'

    let(:ledger_config) do
      <<~YAML
        repo_name: test
        sync:
          ledger_branch: eluent-sync
      YAML
    end

    it 'caches ledger syncers by repo path' do
      setup_repo('/project', config_yaml: ledger_config)

      router.route({ id: 'req-1', cmd: 'ledger_sync', args: { repo_path: '/project', action: 'status' } })
      router.route({ id: 'req-2', cmd: 'ledger_sync', args: { repo_path: '/project', action: 'status' } })

      expect(router.send(:ledger_syncer_cache).keys).to eq(['/project'])
    end
  end
end
