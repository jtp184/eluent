# frozen_string_literal: true

# ==============================================================================
# LedgerSyncer Specs
# ==============================================================================
#
# LedgerSyncer coordinates multi-agent work by maintaining a dedicated git worktree
# for the ledger branch. These tests verify:
#
# 1. Data types: ClaimResult, SetupResult, SyncResult value objects
# 2. State checks: available?, online?, healthy? predicates
# 3. Lifecycle: setup!/teardown! infrastructure management
# 4. Core ops: claim_and_push with optimistic locking, pull/push ledger
# 5. Sync: copying ledger files between worktree and main directory
# 6. Recovery: detecting and rebuilding stale worktrees
#
# Test doubles used:
# - git_adapter: GitAdapter instance double
# - global_paths: GlobalPaths instance double
# - repository: JsonlRepository instance double
# - clock: Time class double (frozen at 2026-01-20 12:00:00 UTC)

require 'json'
require 'fileutils'

RSpec.describe Eluent::Sync::LedgerSyncer do
  let(:repo_path) { '/test/repo' }
  let(:repo_name) { 'test-repo' }
  let(:worktree_path) { '/home/user/.eluent/test-repo/.sync-worktree' }
  let(:branch) { 'eluent-sync' }
  let(:remote) { 'origin' }
  let(:frozen_time) { Time.utc(2026, 1, 20, 12, 0, 0) }
  let(:clock) { class_double(Time, now: frozen_time) }

  let(:repository) { instance_double('Eluent::Storage::JsonlRepository', root_path: repo_path) }
  let(:git_adapter) { instance_double('Eluent::Sync::GitAdapter', repo_path: repo_path) }
  let(:global_paths) do
    instance_double(
      'Eluent::Storage::GlobalPaths',
      sync_worktree_dir: worktree_path,
      ledger_sync_state_file: '/home/user/.eluent/test-repo/.ledger-sync-state',
      ledger_lock_file: '/home/user/.eluent/test-repo/.ledger.lock'
    )
  end

  let(:syncer) do
    described_class.new(
      repository: repository,
      git_adapter: git_adapter,
      global_paths: global_paths,
      remote: remote,
      branch: branch,
      clock: clock
    )
  end

  # Helper to create a WorktreeInfo
  def worktree_info(path:, branch:, commit: 'abc123')
    Eluent::Sync::WorktreeInfo.new(path: path, commit: commit, branch: branch)
  end

  # ===========================================================================
  # Constants
  # ===========================================================================

  describe 'constants' do
    it 'defines LEDGER_BRANCH as the default branch name' do
      expect(described_class::LEDGER_BRANCH).to eq('eluent-sync')
    end

    it 'defines MAX_RETRIES for push conflict handling' do
      expect(described_class::MAX_RETRIES).to eq(5)
    end

    it 'defines BASE_BACKOFF_MS for retry delays' do
      expect(described_class::BASE_BACKOFF_MS).to eq(100)
    end

    it 'defines MAX_BACKOFF_MS to cap retry delays' do
      expect(described_class::MAX_BACKOFF_MS).to eq(5000)
    end

    it 'defines JITTER_FACTOR for randomization' do
      expect(described_class::JITTER_FACTOR).to eq(0.2)
    end
  end

  # ===========================================================================
  # Data Types
  # ===========================================================================

  describe Eluent::Sync::LedgerSyncer::ClaimResult do
    it 'defaults optional fields: error=nil, claimed_by=nil, retries=0, offline_claim=false' do
      result = described_class.new(success: true)

      expect(result.success).to be true
      expect(result.error).to be_nil
      expect(result.claimed_by).to be_nil
      expect(result.retries).to eq(0)
      expect(result.offline_claim).to be false
    end

    it 'captures failure details: error message, competing agent, and retry count' do
      result = described_class.new(
        success: false,
        error: 'Already claimed',
        claimed_by: 'agent-1',
        retries: 3,
        offline_claim: true
      )

      expect(result.success).to be false
      expect(result.error).to eq('Already claimed')
      expect(result.claimed_by).to eq('agent-1')
      expect(result.retries).to eq(3)
      expect(result.offline_claim).to be true
    end
  end

  describe Eluent::Sync::LedgerSyncer::SetupResult do
    it 'defaults optional fields: error=nil, created_branch=false, created_worktree=false' do
      result = described_class.new(success: true)

      expect(result.success).to be true
      expect(result.error).to be_nil
      expect(result.created_branch).to be false
      expect(result.created_worktree).to be false
    end

    it 'indicates which resources were created during setup' do
      result = described_class.new(success: true, created_branch: true, created_worktree: true)

      expect(result.created_branch).to be true
      expect(result.created_worktree).to be true
    end
  end

  describe Eluent::Sync::LedgerSyncer::SyncResult do
    it 'defaults optional fields: error=nil, conflicts=[], changes_applied=0' do
      result = described_class.new(success: true)

      expect(result.success).to be true
      expect(result.error).to be_nil
      expect(result.conflicts).to eq([])
      expect(result.changes_applied).to eq(0)
    end

    it 'captures atom IDs that had merge conflicts' do
      result = described_class.new(success: false, conflicts: %w[TSV1 TSV2], error: 'Merge conflict')

      expect(result.conflicts).to eq(%w[TSV1 TSV2])
    end
  end

  # ===========================================================================
  # Initialization
  # ===========================================================================

  describe '#initialize' do
    it 'accepts all configuration parameters' do
      expect(syncer.repository).to eq(repository)
      expect(syncer.git_adapter).to eq(git_adapter)
      expect(syncer.global_paths).to eq(global_paths)
      expect(syncer.remote).to eq('origin')
      expect(syncer.branch).to eq('eluent-sync')
      expect(syncer.max_retries).to eq(5)
    end

    it 'clamps max_retries to minimum of 1' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths, max_retries: 0
      )
      expect(syncer.max_retries).to eq(1)
    end

    it 'clamps max_retries to maximum of 100' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths, max_retries: 500
      )
      expect(syncer.max_retries).to eq(100)
    end

    it 'uses default remote of origin' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths
      )
      expect(syncer.remote).to eq('origin')
    end

    it 'uses default branch of eluent-sync' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths
      )
      expect(syncer.branch).to eq('eluent-sync')
    end
  end

  # ===========================================================================
  # State Checks
  # ===========================================================================

  describe '#available?' do
    before do
      allow(git_adapter).to receive(:worktree_list).and_return([])
      allow(git_adapter).to receive(:branch_exists?).and_return(false)
    end

    it 'returns true when worktree exists and local branch exists' do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:branch_exists?).with(branch).and_return(true)

      expect(syncer.available?).to be true
    end

    it 'returns true when worktree exists and remote branch exists' do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:branch_exists?).with(branch).and_return(false)
      allow(git_adapter).to receive(:branch_exists?).with(branch, remote: remote).and_return(true)

      expect(syncer.available?).to be true
    end

    it 'returns false when worktree does not exist' do
      allow(git_adapter).to receive(:worktree_list).and_return([])

      expect(syncer.available?).to be false
    end

    it 'returns false when neither local nor remote branch exists' do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:branch_exists?).with(branch).and_return(false)
      allow(git_adapter).to receive(:branch_exists?).with(branch, remote: remote).and_return(false)

      expect(syncer.available?).to be false
    end
  end

  describe '#online?' do
    it 'returns true when remote branch SHA can be retrieved' do
      allow(git_adapter).to receive(:remote_branch_sha).with(remote: remote, branch: branch).and_return('abc123')

      expect(syncer.online?).to be true
    end

    it 'returns false when GitError is raised' do
      allow(git_adapter).to receive(:remote_branch_sha).and_raise(Eluent::Sync::GitError.new('Network error'))

      expect(syncer.online?).to be false
    end

    it 'returns false when GitTimeoutError is raised' do
      allow(git_adapter).to receive(:remote_branch_sha).and_raise(Eluent::Sync::GitTimeoutError.new('Timeout'))

      expect(syncer.online?).to be false
    end
  end

  describe '#healthy?' do
    before do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:branch_exists?).with(branch).and_return(true)
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
    end

    it 'returns true when available and worktree is valid' do
      expect(syncer.healthy?).to be true
    end

    it 'returns false when not available' do
      allow(git_adapter).to receive(:worktree_list).and_return([])

      expect(syncer.healthy?).to be false
    end

    it 'returns false when worktree is stale' do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: 'wrong-branch')])

      expect(syncer.healthy?).to be false
    end
  end

  # ===========================================================================
  # Setup & Teardown
  # ===========================================================================

  describe '#setup!' do
    before do
      allow(global_paths).to receive(:ensure_directories!)
      allow(git_adapter).to receive(:branch_exists?).and_return(false)
      allow(git_adapter).to receive(:worktree_list).and_return([])
      allow(git_adapter).to receive(:current_branch).and_return('main')
      allow(git_adapter).to receive(:create_orphan_branch)
      allow(git_adapter).to receive(:push_branch)
      allow(git_adapter).to receive(:checkout)
      allow(git_adapter).to receive(:worktree_add).and_return(worktree_info(path: worktree_path, branch: branch))
      allow(Dir).to receive(:exist?).and_return(false)
      allow(Dir).to receive(:empty?).and_return(true)
    end

    it 'creates directories via global_paths' do
      expect(global_paths).to receive(:ensure_directories!)

      syncer.setup!
    end

    it 'creates branch when neither local nor remote exists' do
      expect(git_adapter).to receive(:create_orphan_branch).with(branch, initial_message: 'Initialize ledger branch')
      expect(git_adapter).to receive(:push_branch).with(remote: remote, branch: branch, set_upstream: true)

      result = syncer.setup!

      expect(result.success).to be true
      expect(result.created_branch).to be true
    end

    it 'skips branch creation when local branch exists' do
      allow(git_adapter).to receive(:branch_exists?).with(branch).and_return(true)
      expect(git_adapter).not_to receive(:create_orphan_branch)

      result = syncer.setup!

      expect(result.created_branch).to be false
    end

    it 'skips branch creation when remote branch exists' do
      allow(git_adapter).to receive(:branch_exists?).with(branch, remote: remote).and_return(true)
      expect(git_adapter).not_to receive(:create_orphan_branch)

      result = syncer.setup!

      expect(result.created_branch).to be false
    end

    it 'creates worktree when it does not exist' do
      expect(git_adapter).to receive(:worktree_add).with(path: worktree_path, branch: branch)

      result = syncer.setup!

      expect(result.created_worktree).to be true
    end

    it 'skips worktree creation when it already exists' do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      expect(git_adapter).not_to receive(:worktree_add)

      result = syncer.setup!

      expect(result.created_worktree).to be false
    end

    it 'returns error result on GitError' do
      allow(git_adapter).to receive(:create_orphan_branch).and_raise(Eluent::Sync::GitError.new('Failed'))

      result = syncer.setup!

      expect(result.success).to be false
      expect(result.error).to include('Failed')
    end

    it 'returns error result on BranchError' do
      allow(git_adapter).to receive(:create_orphan_branch).and_raise(Eluent::Sync::BranchError.new('Invalid'))

      result = syncer.setup!

      expect(result.success).to be false
      expect(result.error).to include('Invalid')
    end

    it 'restores original branch on failure' do
      allow(git_adapter).to receive(:push_branch).and_raise(Eluent::Sync::GitError.new('Push failed'))
      expect(git_adapter).to receive(:checkout).with('main')

      syncer.setup!
    end
  end

  describe '#teardown!' do
    before do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:worktree_remove)
      allow(git_adapter).to receive(:worktree_prune)
      allow(File).to receive(:exist?).and_return(false)
    end

    it 'removes the worktree' do
      expect(git_adapter).to receive(:worktree_remove).with(path: worktree_path, force: true)

      syncer.teardown!
    end

    it 'prunes worktrees' do
      expect(git_adapter).to receive(:worktree_prune)

      syncer.teardown!
    end

    it 'cleans up state files when they exist' do
      expect(FileUtils).to receive(:rm_f).with(global_paths.ledger_sync_state_file)
      expect(FileUtils).to receive(:rm_f).with(global_paths.ledger_lock_file)

      syncer.teardown!
    end

    it 'returns true on success' do
      expect(syncer.teardown!).to be true
    end

    it 'raises LedgerSyncerError on WorktreeError' do
      allow(git_adapter).to receive(:worktree_remove).and_raise(Eluent::Sync::WorktreeError.new('Locked'))

      expect { syncer.teardown! }.to raise_error(Eluent::Sync::LedgerSyncerError, /Teardown failed/)
    end

    it 'does nothing when worktree does not exist' do
      allow(git_adapter).to receive(:worktree_list).and_return([])
      expect(git_adapter).not_to receive(:worktree_remove)

      syncer.teardown!
    end
  end

  # ===========================================================================
  # Core Operations
  # ===========================================================================

  describe '#claim_and_push' do
    let(:atom_id) { 'TSV4' }
    let(:agent_id) { 'agent-1' }
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:atom_record) { { _type: 'atom', id: atom_id, status: 'open', assignee: nil } }

    before do
      # Worktree health check stubs
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')

      # Pull (fetch + reset) stubs
      allow(git_adapter).to receive(:fetch_branch)

      # Atom file stubs
      allow(File).to receive(:exist?).with(data_file).and_return(true)
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(atom_record)}\n")
      allow(File).to receive(:readlines).with(data_file).and_return(["#{JSON.generate(atom_record)}\n"])
      # Atomic write stubs: temp file write then rename
      allow(File).to receive(:write).with(/\.tmp$/, anything)
      allow(File).to receive(:rename)

      # Push stub
      allow(git_adapter).to receive(:push_branch)
    end

    it 'succeeds on first attempt when no conflicts' do
      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be true
      expect(result.claimed_by).to eq(agent_id)
      expect(result.retries).to eq(0)
    end

    it 'fails with descriptive error when atom does not exist' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)

      result = syncer.claim_and_push(atom_id: 'NONEXISTENT', agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('Atom not found')
    end

    it 'fails when atom_id is nil' do
      result = syncer.claim_and_push(atom_id: nil, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end

    it 'fails when atom_id is empty string' do
      result = syncer.claim_and_push(atom_id: '', agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end

    it 'fails when atom_id is only whitespace' do
      result = syncer.claim_and_push(atom_id: '   ', agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end

    it 'fails when agent_id is nil' do
      result = syncer.claim_and_push(atom_id: atom_id, agent_id: nil)

      expect(result.success).to be false
      expect(result.error).to include('agent_id cannot be nil or empty')
    end

    it 'fails when agent_id is empty string' do
      result = syncer.claim_and_push(atom_id: atom_id, agent_id: '')

      expect(result.success).to be false
      expect(result.error).to include('agent_id cannot be nil or empty')
    end

    it 'rejects claims on closed atoms (terminal state)' do
      closed_atom = atom_record.merge(status: 'closed')
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(closed_atom)}\n")

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('closed')
    end

    it 'rejects claims on discarded atoms (terminal state)' do
      discarded_atom = atom_record.merge(status: 'discard')
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(discarded_atom)}\n")

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('discard')
    end

    it 'is idempotent: succeeds when same agent already owns the claim' do
      claimed_by_self = atom_record.merge(status: 'in_progress', assignee: agent_id)
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(claimed_by_self)}\n")

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be true
      expect(result.claimed_by).to eq(agent_id)
    end

    it 'fails when another agent owns the claim, reports the owner' do
      claimed_by_other = atom_record.merge(status: 'in_progress', assignee: 'agent-2')
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(claimed_by_other)}\n")

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('Already claimed')
      expect(result.claimed_by).to eq('agent-2')
    end

    it 'reports retry count when claim lost due to push conflict' do
      # First attempt: claim succeeds, push fails (triggering retry)
      # Second attempt: atom now claimed by another agent
      attempt = 0
      allow(git_adapter).to receive(:push_branch) do
        attempt += 1
        raise Eluent::Sync::BranchError.new('Push rejected') if attempt == 1
      end
      allow(syncer).to receive(:sleep)

      # After first retry, simulate atom being claimed by another agent
      allow(File).to receive(:foreach).with(data_file) do |&block|
        atom = if attempt == 0
                 atom_record # open
               else
                 atom_record.merge(status: 'in_progress', assignee: 'agent-2')
               end
        block.call("#{JSON.generate(atom)}\n")
      end

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('Already claimed')
      expect(result.retries).to eq(1)
    end

    it 'retries with backoff on push conflict, succeeds when conflict resolves' do
      call_count = 0
      allow(git_adapter).to receive(:push_branch) do
        call_count += 1
        raise Eluent::Sync::BranchError.new('Push rejected') if call_count == 1
      end
      allow(syncer).to receive(:sleep)

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be true
      expect(result.retries).to be >= 1
    end

    it 'fails after exhausting MAX_RETRIES attempts' do
      allow(git_adapter).to receive(:push_branch).and_raise(Eluent::Sync::BranchError.new('Push rejected'))
      allow(syncer).to receive(:sleep)

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to eq('Max retries exceeded')
      expect(result.retries).to eq(5)
    end

    it 'fails when data.jsonl file is missing' do
      allow(File).to receive(:exist?).with(data_file).and_return(false)
      allow(File).to receive(:foreach).with(data_file).and_return([].each)

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(result.success).to be false
      expect(result.error).to include('Atom not found')
    end

    it 'performs atomic write via temp file during claim' do
      temp_file = "#{data_file}.#{Process.pid}.tmp"

      expect(File).to receive(:write).with(temp_file, anything).ordered
      expect(File).to receive(:rename).with(temp_file, data_file).ordered

      syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)
    end

    it 'cleans up temp file if write fails' do
      temp_file = "#{data_file}.#{Process.pid}.tmp"
      allow(File).to receive(:write).with(temp_file, anything).and_raise(Errno::ENOSPC, 'No space left')
      allow(FileUtils).to receive(:rm_f)

      result = syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)

      expect(FileUtils).to have_received(:rm_f).with(temp_file)
      expect(result.success).to be false
      expect(result.error).to include('Failed to update atom')
    end

    it 'recovers stale worktree before attempting claim' do
      # First few calls show stale (wrong branch), then empty (after removal), then valid (after add)
      call_count = 0
      allow(git_adapter).to receive(:worktree_list) do
        call_count += 1
        case call_count
        when 1, 2
          [worktree_info(path: worktree_path, branch: 'wrong-branch')]
        when 3
          [] # After worktree_remove
        else
          [worktree_info(path: worktree_path, branch: branch)]
        end
      end
      allow(git_adapter).to receive(:worktree_remove)
      allow(git_adapter).to receive(:worktree_prune)
      allow(git_adapter).to receive(:worktree_add).and_return(worktree_info(path: worktree_path, branch: branch))

      expect(git_adapter).to receive(:worktree_remove).with(path: worktree_path, force: true)

      syncer.claim_and_push(atom_id: atom_id, agent_id: agent_id)
    end
  end

  describe '#pull_ledger' do
    before do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
      allow(git_adapter).to receive(:fetch_branch)
    end

    it 'fetches and resets to remote branch' do
      expect(git_adapter).to receive(:fetch_branch).with(remote: remote, branch: branch)
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'reset', '--hard', "#{remote}/#{branch}")

      result = syncer.pull_ledger

      expect(result.success).to be true
    end

    it 'returns error on fetch failure' do
      allow(git_adapter).to receive(:fetch_branch).and_raise(Eluent::Sync::BranchError.new('Network error'))

      result = syncer.pull_ledger

      expect(result.success).to be false
      expect(result.error).to include('Pull failed')
    end
  end

  describe '#push_ledger' do
    before do
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
      allow(git_adapter).to receive(:push_branch)
    end

    it 'stages, commits, and pushes changes' do
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'add', '-A')
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'commit', '-m', anything)
      expect(git_adapter).to receive(:push_branch).with(remote: remote, branch: branch)

      result = syncer.push_ledger

      expect(result.success).to be true
    end

    it 'skips commit when no changes' do
      allow(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'status', '--porcelain').and_return('')
      expect(git_adapter).not_to receive(:run_git_in_worktree).with(worktree_path, 'commit', '-m', anything)

      syncer.push_ledger
    end

    it 'returns error on push failure' do
      allow(git_adapter).to receive(:push_branch).and_raise(Eluent::Sync::BranchError.new('Rejected'))

      result = syncer.push_ledger

      expect(result.success).to be false
      expect(result.error).to include('Push failed')
    end
  end

  # ===========================================================================
  # Sync Operations
  # ===========================================================================

  describe '#sync_to_main' do
    let(:worktree_ledger) { "#{worktree_path}/.eluent" }
    let(:main_ledger) { "#{repo_path}/.eluent" }

    before do
      allow(Dir).to receive(:exist?).with(worktree_ledger).and_return(true)
      allow(Dir).to receive(:glob).and_return([])
      allow(FileUtils).to receive(:mkdir_p)
      allow(FileUtils).to receive(:cp)
    end

    it 'copies files from worktree to main' do
      allow(Dir).to receive(:glob).and_return(["#{worktree_ledger}/data.jsonl"])
      allow(File).to receive(:directory?).and_return(false)

      expect(FileUtils).to receive(:cp).with("#{worktree_ledger}/data.jsonl", "#{main_ledger}/data.jsonl")

      result = syncer.sync_to_main

      expect(result.success).to be true
    end

    it 'returns error when worktree ledger does not exist' do
      allow(Dir).to receive(:exist?).with(worktree_ledger).and_return(false)

      result = syncer.sync_to_main

      expect(result.success).to be false
      expect(result.error).to include('not found')
    end
  end

  describe '#seed_from_main' do
    let(:worktree_ledger) { "#{worktree_path}/.eluent" }
    let(:main_ledger) { "#{repo_path}/.eluent" }

    before do
      allow(Dir).to receive(:exist?).with(main_ledger).and_return(true)
      allow(Dir).to receive(:glob).and_return([])
      allow(FileUtils).to receive(:mkdir_p)
      allow(FileUtils).to receive(:cp)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
    end

    it 'copies files from main to worktree and commits' do
      allow(Dir).to receive(:glob).and_return(["#{main_ledger}/data.jsonl"])
      allow(File).to receive(:directory?).and_return(false)

      # git add, git status (showing changes), then git commit
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'add', '-A').ordered
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'status', '--porcelain')
        .and_return(' M data.jsonl').ordered
      expect(git_adapter).to receive(:run_git_in_worktree).with(worktree_path, 'commit', '-m', 'Seed ledger from main branch').ordered

      expect(FileUtils).to receive(:cp).with("#{main_ledger}/data.jsonl", "#{worktree_ledger}/data.jsonl")

      result = syncer.seed_from_main

      expect(result.success).to be true
    end

    it 'returns success when main ledger does not exist (bootstrap case)' do
      allow(Dir).to receive(:exist?).with(main_ledger).and_return(false)

      result = syncer.seed_from_main

      expect(result.success).to be true
    end
  end

  describe '#release_claim' do
    let(:atom_id) { 'TSV4' }
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:claimed_atom) { { _type: 'atom', id: atom_id, status: 'in_progress', assignee: 'agent-1' } }

    before do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
      allow(git_adapter).to receive(:fetch_branch)
      allow(git_adapter).to receive(:push_branch)
      allow(File).to receive(:exist?).with(data_file).and_return(true)
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(claimed_atom)}\n")
      allow(File).to receive(:readlines).with(data_file).and_return(["#{JSON.generate(claimed_atom)}\n"])
      # Atomic write stubs: temp file write then rename
      allow(File).to receive(:write).with(/\.tmp$/, anything)
      allow(File).to receive(:rename)
    end

    it 'releases claim by setting status to open and clearing assignee' do
      temp_file = "#{data_file}.#{Process.pid}.tmp"
      expect(File).to receive(:write).with(temp_file, anything) do |_, content|
        record = JSON.parse(content.strip, symbolize_names: true)
        expect(record[:status]).to eq('open')
        expect(record[:assignee]).to be_nil
      end
      expect(File).to receive(:rename).with(temp_file, data_file)

      result = syncer.release_claim(atom_id: atom_id)

      expect(result.success).to be true
    end

    it 'returns error when atom not found' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)

      result = syncer.release_claim(atom_id: 'NONEXISTENT')

      expect(result.success).to be false
      expect(result.error).to include('Atom not found')
    end

    it 'returns success when atom is already open (no-op)' do
      open_atom = { _type: 'atom', id: atom_id, status: 'open', assignee: nil }
      allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(open_atom)}\n")

      result = syncer.release_claim(atom_id: atom_id)

      expect(result.success).to be true
    end

    it 'fails when atom_id is nil' do
      result = syncer.release_claim(atom_id: nil)

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end

    it 'fails when atom_id is empty string' do
      result = syncer.release_claim(atom_id: '')

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end
  end

  # ===========================================================================
  # Recovery
  # ===========================================================================

  describe '#worktree_stale?' do
    before do
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
    end

    it 'returns false when worktree directory does not exist (nothing to recover)' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(false)

      expect(syncer.worktree_stale?).to be false
    end

    it 'returns true when directory exists but .git file is missing (corrupted)' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(false)

      expect(syncer.worktree_stale?).to be true
    end

    it 'returns true when git cannot validate the worktree (broken linkage)' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:run_git_in_worktree).and_raise(Eluent::Sync::GitError.new('Not a repo'))

      expect(syncer.worktree_stale?).to be true
    end

    it 'returns true when worktree is on wrong branch (misconfigured)' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: 'wrong-branch')])

      expect(syncer.worktree_stale?).to be true
    end

    it 'returns true when worktree directory exists but is not in git registry (orphaned directory)' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
      # Worktree not in registry (e.g., after manual directory copy)
      allow(git_adapter).to receive(:worktree_list).and_return([])

      expect(syncer.worktree_stale?).to be true
    end

    it 'returns false when worktree passes all validation checks' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')

      expect(syncer.worktree_stale?).to be false
    end
  end

  describe '#recover_stale_worktree!' do
    before do
      allow(git_adapter).to receive(:worktree_remove)
      allow(git_adapter).to receive(:worktree_prune)
      allow(git_adapter).to receive(:worktree_add).and_return(worktree_info(path: worktree_path, branch: branch))
    end

    it 'force-removes the stale worktree, prunes, and recreates it' do
      # Stale: directory exists but .git file is missing
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(false)
      allow(git_adapter).to receive(:worktree_list).and_return([])

      expect(git_adapter).to receive(:worktree_remove).with(path: worktree_path, force: true)
      expect(git_adapter).to receive(:worktree_prune)
      expect(git_adapter).to receive(:worktree_add).with(path: worktree_path, branch: branch)

      syncer.recover_stale_worktree!
    end

    it 'is a no-op when worktree is healthy (not stale)' do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(false)
      allow(git_adapter).to receive(:worktree_list).and_return([])
      expect(git_adapter).not_to receive(:worktree_remove)

      syncer.recover_stale_worktree!
    end
  end

  describe '#reconcile_offline_claims!' do
    let(:mock_state) { instance_double('Eluent::Sync::LedgerSyncState') }

    it 'returns empty array when state has no offline claims' do
      allow(mock_state).to receive(:offline_claims?).and_return(false)

      expect(syncer.reconcile_offline_claims!(state: mock_state)).to eq([])
    end

    context 'with offline claims' do
      let(:offline_claim) do
        Eluent::Sync::OfflineClaim.new(
          atom_id: 'TSV1',
          agent_id: 'agent-1',
          claimed_at: frozen_time
        )
      end
      let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
      let(:open_atom) do
        { _type: 'atom', id: 'TSV1', status: 'open', assignee: nil, updated_at: frozen_time.utc.iso8601 }
      end

      before do
        allow(mock_state).to receive(:offline_claims?).and_return(true)
        allow(mock_state).to receive(:offline_claims).and_return([offline_claim])
        allow(mock_state).to receive(:clear_offline_claim)
        allow(mock_state).to receive(:save)

        # Setup for worktree operations
        allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
        allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
        allow(File).to receive(:exist?).with(File.join(worktree_path, '.git')).and_return(true)
        allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
        allow(git_adapter).to receive(:fetch_branch)
        allow(git_adapter).to receive(:push_branch)

        # Setup for atom operations
        allow(File).to receive(:exist?).with(data_file).and_return(true)
        allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(open_atom)}\n")
        allow(File).to receive(:readlines).with(data_file).and_return(["#{JSON.generate(open_atom)}\n"])
        allow(File).to receive(:write)
        allow(File).to receive(:rename)
        allow(FileUtils).to receive(:rm_f)
      end

      it 'attempts to claim each offline claim' do
        result = syncer.reconcile_offline_claims!(state: mock_state)

        expect(result.size).to eq(1)
        expect(result.first[:atom_id]).to eq('TSV1')
        expect(result.first[:success]).to be true
      end

      it 'clears successfully reconciled claims from state' do
        expect(mock_state).to receive(:clear_offline_claim).with(atom_id: 'TSV1')
        expect(mock_state).to receive(:save)

        syncer.reconcile_offline_claims!(state: mock_state)
      end

      it 'reports conflicts when atom is already claimed by another agent' do
        claimed_atom = open_atom.merge(status: 'in_progress', assignee: 'other-agent')
        allow(File).to receive(:foreach).with(data_file).and_yield("#{JSON.generate(claimed_atom)}\n")

        result = syncer.reconcile_offline_claims!(state: mock_state)

        expect(result.first[:success]).to be false
        expect(result.first[:conflict]).to be true
      end

      it 'handles atoms deleted remotely' do
        allow(File).to receive(:foreach).with(data_file).and_return([].each)

        expect(mock_state).to receive(:clear_offline_claim).with(atom_id: 'TSV1')

        result = syncer.reconcile_offline_claims!(state: mock_state)

        expect(result.first[:success]).to be false
        expect(result.first[:atom_deleted]).to be true
      end
    end
  end

  # ===========================================================================
  # Stale Claim Management
  # ===========================================================================

  describe '#stale_claims' do
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:three_hours_ago) { frozen_time - (3 * 3600) }
    let(:one_hour_ago) { frozen_time - 3600 }
    let(:threshold) { frozen_time - (2 * 3600) } # 2 hours ago

    let(:stale_atom) do
      {
        _type: 'atom', id: 'TSV1', status: 'in_progress',
        assignee: 'agent-1', updated_at: three_hours_ago.utc.iso8601
      }
    end

    let(:fresh_atom) do
      {
        _type: 'atom', id: 'TSV2', status: 'in_progress',
        assignee: 'agent-2', updated_at: one_hour_ago.utc.iso8601
      }
    end

    let(:open_atom) do
      {
        _type: 'atom', id: 'TSV3', status: 'open',
        assignee: nil, updated_at: three_hours_ago.utc.iso8601
      }
    end

    before do
      allow(File).to receive(:exist?).with(data_file).and_return(true)
    end

    it 'returns in_progress atoms with updated_at before threshold' do
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(stale_atom)}\n")
        .and_yield("#{JSON.generate(fresh_atom)}\n")

      result = syncer.stale_claims(updated_before: threshold)

      expect(result.size).to eq(1)
      expect(result.first[:id]).to eq('TSV1')
    end

    it 'excludes atoms in open status even if old' do
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(open_atom)}\n")

      result = syncer.stale_claims(updated_before: threshold)

      expect(result).to be_empty
    end

    it 'excludes atoms with updated_at after the threshold' do
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(fresh_atom)}\n")

      result = syncer.stale_claims(updated_before: threshold)

      expect(result).to be_empty
    end

    it 'returns empty array when data file does not exist' do
      allow(File).to receive(:exist?).with(data_file).and_return(false)

      result = syncer.stale_claims(updated_before: threshold)

      expect(result).to eq([])
    end

    it 'skips records without updated_at timestamp' do
      atom_no_timestamp = stale_atom.reject { |k, _| k == :updated_at }
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(atom_no_timestamp)}\n")

      result = syncer.stale_claims(updated_before: threshold)

      expect(result).to be_empty
    end

    it 'handles malformed JSON lines gracefully' do
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("not valid json\n")
        .and_yield("#{JSON.generate(stale_atom)}\n")

      result = syncer.stale_claims(updated_before: threshold)

      expect(result.size).to eq(1)
      expect(result.first[:id]).to eq('TSV1')
    end

    it 'handles invalid timestamp formats gracefully' do
      atom_bad_timestamp = stale_atom.merge(updated_at: 'not-a-timestamp')
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(atom_bad_timestamp)}\n")

      result = syncer.stale_claims(updated_before: threshold)

      expect(result).to be_empty
    end
  end

  describe '#release_stale_claims' do
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:three_hours_ago) { frozen_time - (3 * 3600) }
    let(:threshold) { frozen_time - (2 * 3600) }

    let(:stale_atom1) do
      {
        _type: 'atom', id: 'TSV1', status: 'in_progress',
        assignee: 'agent-1', updated_at: three_hours_ago.utc.iso8601
      }
    end

    let(:stale_atom2) do
      {
        _type: 'atom', id: 'TSV2', status: 'in_progress',
        assignee: 'agent-2', updated_at: three_hours_ago.utc.iso8601
      }
    end

    before do
      allow(File).to receive(:exist?).with(data_file).and_return(true)
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(stale_atom1)}\n")
      allow(File).to receive(:readlines).with(data_file)
        .and_return(["#{JSON.generate(stale_atom1)}\n"])
      allow(File).to receive(:write).with(/\.tmp$/, anything)
      allow(File).to receive(:rename)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
    end

    it 'returns IDs of released atoms' do
      result = syncer.release_stale_claims(updated_before: threshold)

      expect(result).to eq(['TSV1'])
    end

    it 'updates stale atoms to open status with nil assignee' do
      temp_file = "#{data_file}.#{Process.pid}.tmp"
      expect(File).to receive(:write).with(temp_file, anything) do |_, content|
        record = JSON.parse(content.strip, symbolize_names: true)
        expect(record[:status]).to eq('open')
        expect(record[:assignee]).to be_nil
      end

      syncer.release_stale_claims(updated_before: threshold)
    end

    it 'commits with descriptive message for single release' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(git_adapter).to receive(:run_git_in_worktree).with(
        worktree_path, 'commit', '-m', 'Auto-release stale claim on TSV1 (was: agent-1)'
      )

      syncer.release_stale_claims(updated_before: threshold)
    end

    it 'commits with summary message for 2-5 releases' do
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(stale_atom1)}\n")
        .and_yield("#{JSON.generate(stale_atom2)}\n")
      allow(File).to receive(:readlines).with(data_file)
        .and_return(["#{JSON.generate(stale_atom1)}\n", "#{JSON.generate(stale_atom2)}\n"])
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(git_adapter).to receive(:run_git_in_worktree).with(
        worktree_path, 'commit', '-m', 'Auto-release 2 stale claims: TSV1, TSV2'
      )

      syncer.release_stale_claims(updated_before: threshold)
    end

    it 'commits with truncated message for 6+ releases' do
      atoms = (1..6).map do |i|
        { _type: 'atom', id: "TSV#{i}", status: 'in_progress',
          assignee: "agent-#{i}", updated_at: three_hours_ago.utc.iso8601 }
      end

      allow(File).to receive(:foreach).with(data_file) do |_, &block|
        atoms.each { |a| block.call("#{JSON.generate(a)}\n") }
      end
      allow(File).to receive(:readlines).with(data_file)
        .and_return(atoms.map { |a| "#{JSON.generate(a)}\n" })
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(git_adapter).to receive(:run_git_in_worktree).with(
        worktree_path, 'commit', '-m', 'Auto-release 6 stale claims: TSV1, TSV2, TSV3, ...'
      )

      syncer.release_stale_claims(updated_before: threshold)
    end

    it 'returns empty array when no stale claims found' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)

      result = syncer.release_stale_claims(updated_before: threshold)

      expect(result).to eq([])
    end

    it 'does not commit when no stale claims found' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)
      expect(git_adapter).not_to receive(:run_git_in_worktree).with(worktree_path, 'commit', '-m', anything)

      syncer.release_stale_claims(updated_before: threshold)
    end
  end

  describe '#heartbeat' do
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:atom_id) { 'TSV4' }
    let(:agent_id) { 'agent-1' }
    let(:claimed_atom) do
      { _type: 'atom', id: atom_id, status: 'in_progress', assignee: agent_id }
    end

    before do
      # Worktree state checks
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])

      # Pull operations (fetch + reset)
      allow(git_adapter).to receive(:fetch_branch)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')

      # Push operation
      allow(git_adapter).to receive(:push_branch)

      # File operations
      allow(File).to receive(:exist?).with(data_file).and_return(true)
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(claimed_atom)}\n")
      allow(File).to receive(:readlines).with(data_file)
        .and_return(["#{JSON.generate(claimed_atom)}\n"])
      allow(File).to receive(:write).with(/\.tmp$/, anything)
      allow(File).to receive(:rename)
    end

    it 'succeeds for claimed atoms and returns the assignee' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      result = syncer.heartbeat(atom_id: atom_id)

      expect(result.success).to be true
      expect(result.claimed_by).to eq(agent_id)
    end

    it 'pulls latest state before updating' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(git_adapter).to receive(:fetch_branch).with(remote: remote, branch: branch)

      syncer.heartbeat(atom_id: atom_id)
    end

    it 'pushes changes after updating' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(git_adapter).to receive(:push_branch).with(remote: remote, branch: branch)

      syncer.heartbeat(atom_id: atom_id)
    end

    it 'updates the timestamp without changing other fields' do
      temp_file = "#{data_file}.#{Process.pid}.tmp"
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(File).to receive(:write).with(temp_file, anything) do |_, content|
        record = JSON.parse(content.strip, symbolize_names: true)
        expect(record[:status]).to eq('in_progress')
        expect(record[:assignee]).to eq(agent_id)
        expect(record[:updated_at]).to eq(frozen_time.utc.iso8601)
      end

      syncer.heartbeat(atom_id: atom_id)
    end

    it 'commits with heartbeat message' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      expect(git_adapter).to receive(:run_git_in_worktree).with(
        worktree_path, 'commit', '-m', "Heartbeat for #{atom_id}"
      )

      syncer.heartbeat(atom_id: atom_id)
    end

    it 'fails when atom_id is nil' do
      result = syncer.heartbeat(atom_id: nil)

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end

    it 'fails when atom_id is empty' do
      result = syncer.heartbeat(atom_id: '')

      expect(result.success).to be false
      expect(result.error).to include('atom_id cannot be nil or empty')
    end

    it 'fails when atom not found' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)

      result = syncer.heartbeat(atom_id: 'NONEXISTENT')

      expect(result.success).to be false
      expect(result.error).to include('Atom not found')
    end

    it 'fails when atom is not in_progress' do
      open_atom = claimed_atom.merge(status: 'open')
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(open_atom)}\n")

      result = syncer.heartbeat(atom_id: atom_id)

      expect(result.success).to be false
      expect(result.error).to include('Cannot heartbeat atom in open state')
    end

    it 'fails when atom is in terminal state' do
      closed_atom = claimed_atom.merge(status: 'closed')
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(closed_atom)}\n")

      result = syncer.heartbeat(atom_id: atom_id)

      expect(result.success).to be false
      expect(result.error).to include('Cannot heartbeat atom in closed state')
    end

    it 'fails when pull fails' do
      allow(git_adapter).to receive(:fetch_branch)
        .and_raise(Eluent::Sync::BranchError.new('Network error'))

      result = syncer.heartbeat(atom_id: atom_id)

      expect(result.success).to be false
      expect(result.error).to include('Pull failed')
    end

    it 'fails with max retries when push always fails' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')
      allow(git_adapter).to receive(:push_branch)
        .and_raise(Eluent::Sync::GitError.new('Push rejected'))
      allow(syncer).to receive(:sleep)

      result = syncer.heartbeat(atom_id: atom_id)

      expect(result.success).to be false
      expect(result.error).to eq('Max retries exceeded')
      expect(result.retries).to eq(5)
    end

    it 'retries on push conflict and succeeds' do
      allow(git_adapter).to receive(:run_git_in_worktree)
        .with(worktree_path, 'status', '--porcelain').and_return(' M data.jsonl')

      # First push fails, second succeeds
      call_count = 0
      allow(git_adapter).to receive(:push_branch) do
        call_count += 1
        raise Eluent::Sync::GitError, 'Push rejected' if call_count == 1
      end

      # Stub sleep to avoid waiting
      allow(syncer).to receive(:sleep)

      result = syncer.heartbeat(atom_id: atom_id)

      expect(result.success).to be true
      expect(result.retries).to eq(1)
    end

    it 'does not retry on non-push errors' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)
      expect(syncer).not_to receive(:sleep)

      result = syncer.heartbeat(atom_id: 'NONEXISTENT')

      expect(result.success).to be false
      expect(result.retries).to eq(0)
    end
  end

  describe 'claim_timeout_hours configuration' do
    it 'accepts claim_timeout_hours parameter' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths, claim_timeout_hours: 4.0
      )

      expect(syncer.claim_timeout_hours).to eq(4.0)
    end

    it 'normalizes nil claim_timeout_hours' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths, claim_timeout_hours: nil
      )

      expect(syncer.claim_timeout_hours).to be_nil
    end

    it 'normalizes zero claim_timeout_hours to nil (disabled)' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths, claim_timeout_hours: 0
      )

      expect(syncer.claim_timeout_hours).to be_nil
    end

    it 'normalizes negative claim_timeout_hours to nil (disabled)' do
      syncer = described_class.new(
        repository: repository, git_adapter: git_adapter,
        global_paths: global_paths, claim_timeout_hours: -5
      )

      expect(syncer.claim_timeout_hours).to be_nil
    end
  end

  describe '#pull_ledger with auto-release' do
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:three_hours_ago) { frozen_time - (3 * 3600) }
    let(:stale_atom) do
      {
        _type: 'atom', id: 'TSV1', status: 'in_progress',
        assignee: 'agent-1', updated_at: three_hours_ago.utc.iso8601
      }
    end

    let(:syncer_with_timeout) do
      described_class.new(
        repository: repository,
        git_adapter: git_adapter,
        global_paths: global_paths,
        remote: remote,
        branch: branch,
        clock: clock,
        claim_timeout_hours: 2.0 # 2 hour timeout
      )
    end

    before do
      allow(Dir).to receive(:exist?).with(worktree_path).and_return(true)
      allow(File).to receive(:exist?).with("#{worktree_path}/.git").and_return(true)
      allow(git_adapter).to receive(:worktree_list).and_return([worktree_info(path: worktree_path, branch: branch)])
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
      allow(git_adapter).to receive(:fetch_branch)
      allow(git_adapter).to receive(:push_branch)
      allow(File).to receive(:exist?).with(data_file).and_return(true)
      allow(File).to receive(:foreach).with(data_file)
        .and_yield("#{JSON.generate(stale_atom)}\n")
      allow(File).to receive(:readlines).with(data_file)
        .and_return(["#{JSON.generate(stale_atom)}\n"])
      allow(File).to receive(:write).with(/\.tmp$/, anything)
      allow(File).to receive(:rename)
    end

    it 'auto-releases stale claims when claim_timeout_hours is configured' do
      expect(syncer_with_timeout).to receive(:warn).with(/auto-released 1 stale claim/)

      syncer_with_timeout.pull_ledger
    end

    it 'pushes auto-released claims to remote' do
      allow(syncer_with_timeout).to receive(:warn)
      expect(git_adapter).to receive(:push_branch).with(remote: remote, branch: branch)

      syncer_with_timeout.pull_ledger
    end

    it 'retries and logs failure when push consistently fails' do
      allow(git_adapter).to receive(:push_branch)
        .and_raise(Eluent::Sync::GitError.new('Push rejected'))

      # After max_retries, it should log failure and give up
      expect(syncer_with_timeout).to receive(:warn).with(/failed to release stale claims after \d+ retries/)

      result = syncer_with_timeout.pull_ledger
      # Pull still succeeds even if stale claim release fails
      expect(result.success).to be true
    end

    it 'succeeds on push retry after initial conflict' do
      push_attempts = 0
      allow(git_adapter).to receive(:push_branch) do
        push_attempts += 1
        raise Eluent::Sync::GitError.new('Push rejected') if push_attempts < 3
      end

      expect(syncer_with_timeout).to receive(:warn).with(/auto-released 1 stale claim/)

      result = syncer_with_timeout.pull_ledger
      expect(result.success).to be true
    end

    it 'does not auto-release when claim_timeout_hours is nil' do
      expect(syncer).not_to receive(:release_stale_claims)

      syncer.pull_ledger
    end

    it 'does not warn when no stale claims are found' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)
      expect(syncer_with_timeout).not_to receive(:warn)

      syncer_with_timeout.pull_ledger
    end

    it 'does not push when no stale claims are found' do
      allow(File).to receive(:foreach).with(data_file).and_return([].each)
      # Should only call push_branch for the initial commit, not for auto-release
      expect(git_adapter).not_to receive(:push_branch)

      syncer_with_timeout.pull_ledger
    end
  end

  describe '#release_stale_claims batch efficiency' do
    let(:data_file) { "#{worktree_path}/.eluent/data.jsonl" }
    let(:three_hours_ago) { frozen_time - (3 * 3600) }
    let(:threshold) { frozen_time - (2 * 3600) }

    let(:stale_atoms) do
      (1..10).map do |i|
        {
          _type: 'atom', id: "TSV#{i}", status: 'in_progress',
          assignee: "agent-#{i}", updated_at: three_hours_ago.utc.iso8601
        }
      end
    end

    before do
      allow(File).to receive(:exist?).with(data_file).and_return(true)
      allow(File).to receive(:foreach).with(data_file) do |_, &block|
        stale_atoms.each { |atom| block.call("#{JSON.generate(atom)}\n") }
      end
      allow(File).to receive(:readlines).with(data_file)
        .and_return(stale_atoms.map { |a| "#{JSON.generate(a)}\n" })
      allow(File).to receive(:write).with(/\.tmp$/, anything)
      allow(File).to receive(:rename)
      allow(git_adapter).to receive(:run_git_in_worktree).and_return('')
    end

    it 'releases all stale atoms in single file write' do
      # Should only write to temp file once (batch operation)
      write_count = 0
      allow(File).to receive(:write).with(/\.tmp$/, anything) { write_count += 1 }

      syncer.release_stale_claims(updated_before: threshold)

      expect(write_count).to eq(1)
    end

    it 'returns all released atom IDs' do
      result = syncer.release_stale_claims(updated_before: threshold)

      expect(result.size).to eq(10)
      expect(result).to eq((1..10).map { |i| "TSV#{i}" })
    end
  end
end

# ==============================================================================
# LedgerSyncerError
# ==============================================================================

RSpec.describe Eluent::Sync::LedgerSyncerError do
  it 'inherits from Eluent::Error for consistent exception hierarchy' do
    expect(described_class.superclass).to eq(Eluent::Error)
  end
end
