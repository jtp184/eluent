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
      # Note: no .git directory
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
      expect(orchestrator).to receive(:sync).with(hash_including(pull_only: true))
      run_command('--pull-only', robot_mode: true)
    end

    it 'passes push_only option' do
      expect(orchestrator).to receive(:sync).with(hash_including(push_only: true))
      run_command('--push-only', robot_mode: true)
    end

    it 'passes dry_run option' do
      expect(orchestrator).to receive(:sync).with(hash_including(dry_run: true))
      run_command('--dry-run', robot_mode: true)
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
