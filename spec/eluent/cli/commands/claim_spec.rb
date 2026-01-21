# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/claim'

RSpec.describe Eluent::CLI::Commands::Claim do
  let(:root_path) { Dir.mktmpdir }
  let(:atom_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP0A' }
  let(:now) { Time.now.utc.iso8601 }

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    FileUtils.mkdir_p(File.join(root_path, '.git'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      <<~JSONL
        {"_type":"header","repo_name":"testrepo"}
        {"_type":"atom","id":"#{atom_id}","title":"Open Task","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
      JSONL
    )

    allow(Dir).to receive(:pwd).and_return(root_path)
    allow(Socket).to receive(:gethostname).and_return('test-host')
  end

  after do
    FileUtils.rm_rf(root_path)
  end

  def run_command(*args, robot_mode: false)
    described_class.new(args, robot_mode: robot_mode).run
  rescue Eluent::Storage::RepositoryNotFoundError,
         Eluent::Registry::IdNotFoundError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'claiming an atom (local only, no ledger sync configured)' do
    it 'sets status to in_progress' do
      run_command(atom_id)

      data = read_atom_from_file
      expect(data['status']).to eq('in_progress')
    end

    it 'sets assignee to default agent ID' do
      run_command(atom_id)

      data = read_atom_from_file
      expect(data['assignee']).to eq('test-host')
    end

    it 'returns success exit code' do
      expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::SUCCESS)
    end

    it 'outputs success message in robot mode' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['atom_id']).to eq(atom_id)
      expect(parsed['data']['agent_id']).to eq('test-host')
      expect(parsed['data']['offline']).to be true
    end
  end

  describe '--agent-id option' do
    it 'uses custom agent ID' do
      run_command(atom_id, '--agent-id', 'custom-agent')

      data = read_atom_from_file
      expect(data['assignee']).to eq('custom-agent')
    end

    it 'returns custom agent ID in output' do
      output = capture_stdout { run_command(atom_id, '--agent-id', 'custom-agent', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['agent_id']).to eq('custom-agent')
    end
  end

  describe '--quiet option' do
    it 'suppresses success output' do
      output = capture_stdout { run_command(atom_id, '--quiet') }
      expect(output).to be_empty
    end

    it 'returns success exit code' do
      expect(run_command(atom_id, '--quiet')).to eq(Eluent::CLI::Commands::ExitCodes::SUCCESS)
    end
  end

  describe '--force option for already claimed atoms' do
    let(:other_agent) { 'other-agent' }

    before do
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"In Progress Task","status":"in_progress","assignee":"#{other_agent}","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'returns conflict error without --force' do
      expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::CLAIM_CONFLICT)
    end

    it 'outputs conflict error message' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('CLAIM_CONFLICT')
      expect(parsed['error']['message']).to include('other-agent')
    end

    it 'steals claim with --force' do
      run_command(atom_id, '--force')

      data = read_atom_from_file
      expect(data['assignee']).to eq('test-host')
    end

    it 'returns success exit code with --force' do
      expect(run_command(atom_id, '--force', robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::SUCCESS)
    end
  end

  describe 'atom not found' do
    it 'returns NOT_FOUND exit code' do
      expect(run_command('nonexistent', robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::ATOM_NOT_FOUND)
    end

    it 'outputs error message' do
      output = capture_stdout { run_command('nonexistent', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'atom in terminal state' do
    before do
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"Closed Task","status":"closed","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'returns ATOM_TERMINAL exit code for closed atoms' do
      expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::ATOM_TERMINAL)
    end

    it 'outputs error message' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_STATE')
      expect(parsed['error']['message']).to include('closed')
    end
  end

  describe 'atom in discard state' do
    before do
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"Discarded Task","status":"discard","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'returns ATOM_TERMINAL exit code for discarded atoms' do
      expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::ATOM_TERMINAL)
    end
  end

  describe 'not a git repo' do
    before do
      FileUtils.rm_rf(File.join(root_path, '.git'))
    end

    it 'returns LEDGER_NOT_CONFIGURED exit code' do
      expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::LEDGER_NOT_CONFIGURED)
    end

    it 'outputs error message' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NO_GIT_REPO')
    end
  end

  describe 'idempotent claim by same agent' do
    before do
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"Already Claimed","status":"in_progress","assignee":"test-host","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'succeeds when already claimed by same agent' do
      expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::SUCCESS)
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el claim/).to_stdout
    end

    it 'returns 0' do
      expect(run_command('--help')).to eq(0)
    end
  end

  describe 'with ledger sync configured' do
    let(:ledger_syncer) { instance_double(Eluent::Sync::LedgerSyncer) }
    let(:global_paths) { instance_double(Eluent::Storage::GlobalPaths) }
    let(:claim_result) do
      Eluent::Sync::LedgerSyncer::ClaimResult.new(
        success: true,
        claimed_by: 'test-host',
        retries: 0,
        offline_claim: false
      )
    end

    before do
      File.write(
        File.join(root_path, '.eluent', 'config.yaml'),
        YAML.dump('repo_name' => 'testrepo', 'sync' => { 'ledger_branch' => 'eluent-sync' })
      )

      allow(Eluent::Storage::GlobalPaths).to receive(:new).and_return(global_paths)
      allow(Eluent::Sync::LedgerSyncer).to receive(:new).and_return(ledger_syncer)
      allow(ledger_syncer).to receive(:available?).and_return(true)
      allow(ledger_syncer).to receive(:online?).and_return(true)
      allow(ledger_syncer).to receive(:claim_and_push).and_return(claim_result)
    end

    it 'uses ledger syncer for claims' do
      run_command(atom_id, robot_mode: true)

      expect(ledger_syncer).to have_received(:claim_and_push).with(
        atom_id: atom_id,
        agent_id: 'test-host'
      )
    end

    it 'returns success with ledger claim' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['offline']).to be false
    end

    context 'when claim conflicts' do
      let(:claim_result) do
        Eluent::Sync::LedgerSyncer::ClaimResult.new(
          success: false,
          error: 'Already claimed by other-agent',
          claimed_by: 'other-agent',
          retries: 0
        )
      end

      it 'returns CLAIM_CONFLICT exit code' do
        expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::CLAIM_CONFLICT)
      end
    end

    context 'when max retries exhausted' do
      let(:claim_result) do
        Eluent::Sync::LedgerSyncer::ClaimResult.new(
          success: false,
          error: 'Max retries exceeded',
          retries: 5
        )
      end

      it 'returns CLAIM_RETRIES exit code' do
        expect(run_command(atom_id, robot_mode: true)).to eq(Eluent::CLI::Commands::ExitCodes::CLAIM_RETRIES)
      end

      it 'outputs retry count' do
        output = capture_stdout { run_command(atom_id, robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['error']['code']).to eq('MAX_RETRIES')
        expect(parsed['error']['message']).to include('5')
      end
    end

    context 'with --offline flag' do
      let(:ledger_sync_state) { instance_double(Eluent::Sync::LedgerSyncState) }

      before do
        allow(Eluent::Sync::LedgerSyncState).to receive(:new).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive(:load).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive(:record_offline_claim).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive(:save).and_return(ledger_sync_state)
      end

      it 'skips ledger sync and claims locally' do
        run_command(atom_id, '--offline', robot_mode: true)

        expect(ledger_syncer).not_to have_received(:claim_and_push)
      end

      it 'sets atom status locally' do
        run_command(atom_id, '--offline')

        data = read_atom_from_file
        expect(data['status']).to eq('in_progress')
        expect(data['assignee']).to eq('test-host')
      end
    end

    context 'when syncer not available' do
      let(:setup_result) do
        Eluent::Sync::LedgerSyncer::SetupResult.new(success: false, error: 'Setup failed')
      end

      before do
        allow(ledger_syncer).to receive(:available?).and_return(false)
        allow(ledger_syncer).to receive(:online?).and_return(true)
        allow(ledger_syncer).to receive(:setup!).and_return(setup_result)
      end

      it 'returns error when syncer setup fails' do
        output = capture_stdout { run_command(atom_id, robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('error')
        expect(parsed['error']['code']).to eq('LEDGER_ERROR')
      end
    end

    context 'with --offline flag and ledger sync state' do
      let(:ledger_sync_state) { instance_double(Eluent::Sync::LedgerSyncState) }

      before do
        allow(Eluent::Sync::LedgerSyncState).to receive(:new).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive(:load).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive(:record_offline_claim).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive(:save).and_return(ledger_sync_state)
      end

      it 'records offline claim in state' do
        run_command(atom_id, '--offline', robot_mode: true)
        expect(ledger_sync_state).to have_received(:record_offline_claim)
      end
    end
  end

  private

  def read_atom_from_file
    data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
    atom_line = data_lines.reverse.find { |line| line.include?(atom_id) }
    JSON.parse(atom_line)
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
