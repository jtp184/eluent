# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/sync'

RSpec.describe Eluent::CLI::Commands::Sync do
  let(:root_path) { Dir.mktmpdir }
  let(:now) { Time.now.utc.iso8601 }

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    FileUtils.mkdir_p(File.join(root_path, '.git'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      "{\"_type\":\"header\",\"repo_name\":\"testrepo\"}\n"
    )

    allow(Dir).to receive(:pwd).and_return(root_path)
  end

  after do
    FileUtils.rm_rf(root_path)
  end

  def run_command(*args, robot_mode: false)
    described_class.new(args, robot_mode: robot_mode).run
  rescue Eluent::Storage::RepositoryNotFoundError,
         Eluent::Sync::GitError,
         Eluent::Sync::NoRemoteError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'sync without git repo' do
    let(:no_git_path) { Dir.mktmpdir }

    before do
      FileUtils.mkdir_p(File.join(no_git_path, '.eluent', 'formulas'))
      File.write(File.join(no_git_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
      File.write(File.join(no_git_path, '.eluent', 'data.jsonl'), "{\"_type\":\"header\",\"repo_name\":\"testrepo\"}\n")
      # NOTE: no .git directory
      allow(Dir).to receive(:pwd).and_return(no_git_path)
    end

    after do
      FileUtils.rm_rf(no_git_path)
    end

    it 'returns error when not a git repo' do
      expect(run_command(robot_mode: true)).to eq(1)
    end

    it 'outputs NO_GIT_REPO error' do
      output = capture_stdout { run_command(robot_mode: true) }
      # Verify output contains the error code
      expect(output).to include('NO_GIT_REPO')
    end
  end

  describe 'sync without remote' do
    it 'returns error when no remote configured' do
      expect(run_command(robot_mode: true)).to eq(1)
    end

    it 'outputs NO_REMOTE error' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NO_REMOTE')
    end
  end

  describe 'with mocked orchestrator' do
    let(:git_adapter) { instance_double(Eluent::Sync::GitAdapter) }
    let(:sync_state) { instance_double(Eluent::Sync::SyncState) }
    let(:orchestrator) { instance_double(Eluent::Sync::PullFirstOrchestrator) }
    let(:sync_result) do
      Eluent::Sync::PullFirstOrchestrator::SyncResult.new(
        status: :success,
        changes: [],
        conflicts: [],
        commits: []
      )
    end

    before do
      allow(Eluent::Sync::GitAdapter).to receive(:new).and_return(git_adapter)
      allow(Eluent::Sync::SyncState).to receive(:new).and_return(sync_state)
      allow(Eluent::Sync::PullFirstOrchestrator).to receive(:new).and_return(orchestrator)

      allow(git_adapter).to receive(:remote?).and_return(true)
      allow(sync_state).to receive(:load).and_return(sync_state)
      allow(orchestrator).to receive(:sync).and_return(sync_result)
    end

    it 'returns 0 on success' do
      expect(run_command(robot_mode: true)).to eq(0)
    end

    it 'outputs JSON with status' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['status']).to eq('success')
    end

    it 'passes pull_only option' do
      run_command('--pull-only', robot_mode: true)
      expect(orchestrator).to have_received(:sync).with(hash_including(pull_only: true))
    end

    it 'passes push_only option' do
      run_command('--push-only', robot_mode: true)
      expect(orchestrator).to have_received(:sync).with(hash_including(push_only: true))
    end

    it 'passes dry_run option' do
      run_command('--dry-run', robot_mode: true)
      expect(orchestrator).to have_received(:sync).with(hash_including(dry_run: true))
    end

    context 'when up to date' do
      let(:sync_result) do
        Eluent::Sync::PullFirstOrchestrator::SyncResult.new(
          status: :up_to_date,
          changes: [],
          conflicts: [],
          commits: []
        )
      end

      it 'returns 0' do
        expect(run_command(robot_mode: true)).to eq(0)
      end

      it 'outputs up_to_date status' do
        output = capture_stdout { run_command(robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['data']['status']).to eq('up_to_date')
      end
    end

    context 'with conflicts' do
      let(:sync_result) do
        Eluent::Sync::PullFirstOrchestrator::SyncResult.new(
          status: :conflicted,
          changes: [],
          conflicts: [{ id: 'atom1', type: 'modification' }],
          commits: []
        )
      end

      it 'returns 1' do
        expect(run_command(robot_mode: true)).to eq(1)
      end

      it 'outputs conflicted status' do
        output = capture_stdout { run_command(robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('error')
        expect(parsed['data']['conflicts']).not_to be_empty
      end
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el sync/).to_stdout
    end

    it 'returns 0' do
      expect(run_command('--help')).to eq(0)
    end

    it 'includes ledger sync flags in help' do
      expect { run_command('--help') }.to output(/--setup-ledger/).to_stdout
    end
  end

  # ------------------------------------------------------------------
  # Ledger Sync Flags
  # ------------------------------------------------------------------

  describe 'ledger sync operations' do
    let(:git_adapter) { instance_double(Eluent::Sync::GitAdapter) }
    let(:ledger_syncer) { instance_double(Eluent::Sync::LedgerSyncer) }
    let(:ledger_sync_state) { instance_double(Eluent::Sync::LedgerSyncState) }
    let(:global_paths) { instance_double(Eluent::Storage::GlobalPaths) }

    before do
      allow(Eluent::Sync::GitAdapter).to receive(:new).and_return(git_adapter)
      allow(git_adapter).to receive(:remote?).and_return(true)
    end

    describe '--status (without ledger sync configured)' do
      before do
        allow(Eluent::Storage::GlobalPaths).to receive(:new).and_return(global_paths)
        allow(Eluent::Sync::LedgerSyncState).to receive(:new).and_return(ledger_sync_state)
        allow(ledger_sync_state).to receive_messages(
          load: ledger_sync_state, last_pull_at: nil, last_push_at: nil, ledger_head: nil,
          valid?: false, offline_claims: [], offline_claims?: false
        )
      end

      it 'returns 0' do
        expect(run_command('--status', robot_mode: true)).to eq(0)
      end

      it 'shows ledger sync is not configured' do
        output = capture_stdout { run_command('--status', robot_mode: true) }
        parsed = JSON.parse(output)

        expect(parsed['status']).to eq('ok')
        expect(parsed['data']['ledger_sync_enabled']).to be false
      end
    end

    context 'with ledger sync configured' do
      let(:setup_result) do
        Eluent::Sync::LedgerSyncer::SetupResult.new(
          success: true,
          created_branch: true,
          created_worktree: true
        )
      end
      let(:sync_result) do
        Eluent::Sync::LedgerSyncer::SyncResult.new(
          success: true,
          changes_applied: 1
        )
      end

      before do
        File.write(
          File.join(root_path, '.eluent', 'config.yaml'),
          YAML.dump('repo_name' => 'testrepo', 'sync' => { 'ledger_branch' => 'eluent-sync' })
        )

        allow(Eluent::Storage::GlobalPaths).to receive(:new).and_return(global_paths)
        allow(Eluent::Sync::LedgerSyncer).to receive(:new).and_return(ledger_syncer)
        allow(Eluent::Sync::LedgerSyncState).to receive(:new).and_return(ledger_sync_state)

        allow(global_paths).to receive(:sync_worktree_dir).and_return('/home/user/.eluent/testrepo/.sync-worktree')

        allow(ledger_sync_state).to receive(:reset!)
        allow(ledger_sync_state).to receive_messages(
          load: ledger_sync_state, exists?: false, last_pull_at: nil, last_push_at: nil,
          ledger_head: nil, valid?: false, offline_claims: [], offline_claims?: false
        )
      end

      describe '--setup-ledger' do
        before do
          allow(ledger_syncer).to receive(:setup!).and_return(setup_result)
        end

        it 'calls setup! on ledger syncer' do
          run_command('--setup-ledger', robot_mode: true)
          expect(ledger_syncer).to have_received(:setup!)
        end

        it 'returns 0 on success' do
          expect(run_command('--setup-ledger', robot_mode: true)).to eq(0)
        end

        it 'outputs setup result' do
          output = capture_stdout { run_command('--setup-ledger', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('ok')
          expect(parsed['data']['created_branch']).to be true
          expect(parsed['data']['created_worktree']).to be true
        end

        it 'returns 1 when setup fails' do
          failed_result = Eluent::Sync::LedgerSyncer::SetupResult.new(success: false, error: 'Failed to create branch')
          allow(ledger_syncer).to receive(:setup!).and_return(failed_result)
          expect(run_command('--setup-ledger', robot_mode: true)).to eq(1)
        end

        it 'outputs error when setup fails' do
          failed_result = Eluent::Sync::LedgerSyncer::SetupResult.new(success: false, error: 'Failed to create branch')
          allow(ledger_syncer).to receive(:setup!).and_return(failed_result)
          output = capture_stdout { run_command('--setup-ledger', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('error')
          expect(parsed['error']['code']).to eq('SETUP_FAILED')
        end
      end

      describe '--ledger-only' do
        before do
          allow(ledger_syncer).to receive_messages(available?: true, pull_ledger: sync_result,
                                                   push_ledger: sync_result, sync_to_main: sync_result)
        end

        it 'performs ledger pull and push' do
          run_command('--ledger-only', robot_mode: true)

          expect(ledger_syncer).to have_received(:pull_ledger)
          expect(ledger_syncer).to have_received(:push_ledger)
          expect(ledger_syncer).to have_received(:sync_to_main)
        end

        it 'returns 0 on success' do
          expect(run_command('--ledger-only', robot_mode: true)).to eq(0)
        end

        it 'returns error when syncer not available' do
          allow(ledger_syncer).to receive(:available?).and_return(false)
          output = capture_stdout { run_command('--ledger-only', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('error')
          expect(parsed['error']['code']).to eq('LEDGER_NOT_SETUP')
        end
      end

      describe '--cleanup-ledger' do
        before do
          allow(ledger_syncer).to receive(:available?).and_return(true)
          allow(ledger_syncer).to receive(:teardown!)
        end

        it 'requires --force or --yes' do
          expect(run_command('--cleanup-ledger', robot_mode: true)).to eq(1)
        end

        it 'calls teardown! with --force' do
          run_command('--cleanup-ledger', '--force', robot_mode: true)
          expect(ledger_syncer).to have_received(:teardown!)
        end

        it 'calls teardown! with --yes' do
          run_command('--cleanup-ledger', '--yes', robot_mode: true)
          expect(ledger_syncer).to have_received(:teardown!)
        end

        it 'returns 0 on success' do
          expect(run_command('--cleanup-ledger', '--yes', robot_mode: true)).to eq(0)
        end
      end

      describe '--reconcile' do
        before do
          allow(ledger_syncer).to receive_messages(available?: true, reconcile_offline_claims!: [])
        end

        it 'returns 0 with no offline claims' do
          expect(run_command('--reconcile', robot_mode: true)).to eq(0)
        end

        it 'outputs success with no offline claims' do
          output = capture_stdout { run_command('--reconcile', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('ok')
        end

        it 'calls reconcile_offline_claims! with offline claims' do
          offline_claim = Eluent::Sync::OfflineClaim.new(
            atom_id: 'test-atom', agent_id: 'test-agent', claimed_at: Time.now
          )
          allow(ledger_sync_state).to receive_messages(offline_claims?: true, offline_claims: [offline_claim])
          run_command('--reconcile', robot_mode: true)
          expect(ledger_syncer).to have_received(:reconcile_offline_claims!)
        end

        it 'returns 0 with offline claims' do
          offline_claim = Eluent::Sync::OfflineClaim.new(
            atom_id: 'test-atom', agent_id: 'test-agent', claimed_at: Time.now
          )
          allow(ledger_sync_state).to receive_messages(offline_claims?: true, offline_claims: [offline_claim])
          expect(run_command('--reconcile', robot_mode: true)).to eq(0)
        end
      end

      describe '--force-resync' do
        before do
          allow(ledger_syncer).to receive(:teardown!)
          allow(ledger_syncer).to receive_messages(available?: true, setup!: setup_result, pull_ledger: sync_result,
                                                   sync_to_main: sync_result)
        end

        it 'requires --yes confirmation' do
          expect(run_command('--force-resync', robot_mode: true)).to eq(1)
        end

        it 'performs teardown and setup with --yes' do
          run_command('--force-resync', '--yes', robot_mode: true)

          expect(ledger_syncer).to have_received(:teardown!)
          expect(ledger_syncer).to have_received(:setup!)
          expect(ledger_syncer).to have_received(:pull_ledger)
        end

        it 'returns 0 on success' do
          expect(run_command('--force-resync', '--yes', robot_mode: true)).to eq(0)
        end
      end

      describe '--status' do
        before do
          allow(ledger_syncer).to receive_messages(available?: true, healthy?: true, online?: true)
        end

        it 'returns 0' do
          expect(run_command('--status', robot_mode: true)).to eq(0)
        end

        it 'outputs status information' do
          output = capture_stdout { run_command('--status', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('ok')
          expect(parsed['data']['ledger_sync_enabled']).to be true
          expect(parsed['data']['ledger_branch']).to eq('eluent-sync')
          expect(parsed['data']['available']).to be true
          expect(parsed['data']['healthy']).to be true
          expect(parsed['data']['online']).to be true
        end
      end
    end

    context 'without ledger sync configured' do
      describe '--setup-ledger' do
        it 'returns error' do
          output = capture_stdout { run_command('--setup-ledger', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('error')
          expect(parsed['error']['code']).to eq('LEDGER_NOT_CONFIGURED')
        end
      end

      describe '--ledger-only' do
        before do
          allow(git_adapter).to receive(:remote?).and_return(true)
        end

        it 'returns error' do
          output = capture_stdout { run_command('--ledger-only', robot_mode: true) }
          parsed = JSON.parse(output)

          expect(parsed['status']).to eq('error')
          expect(parsed['error']['code']).to eq('LEDGER_NOT_CONFIGURED')
        end
      end
    end
  end

  private

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
