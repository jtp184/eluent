# frozen_string_literal: true

RSpec.describe Eluent::Sync::PullFirstOrchestrator, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }

  let(:git_adapter) { instance_double(Eluent::Sync::GitAdapter) }
  let(:sync_state) { instance_double(Eluent::Sync::SyncState) }
  let(:repository) do
    instance_double(
      Eluent::Storage::JsonlRepository,
      paths: paths,
      repo_name: 'testrepo',
      list_atoms: []
    )
  end

  let(:orchestrator) do
    described_class.new(
      repository: repository,
      git_adapter: git_adapter,
      sync_state: sync_state
    )
  end

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    setup_eluent_directory(root_path)

    allow(git_adapter).to receive_messages(remote?: true, repo_path: root_path)

    # FakeFS doesn't support flock, so we stub the lock behavior
    allow(File).to receive(:open).and_call_original
    allow_any_instance_of(File).to receive(:flock).and_return(true) # rubocop:disable RSpec/AnyInstance
  end

  after { FakeFS.deactivate! }

  describe Eluent::Sync::PullFirstOrchestrator::SyncResult do
    it 'responds to success?' do
      result = described_class.new(status: :success, changes: [], conflicts: [], commits: [])
      expect(result.success?).to be true
      expect(result.up_to_date?).to be false
      expect(result.conflicted?).to be false
    end

    it 'responds to up_to_date?' do
      result = described_class.new(status: :up_to_date, changes: [], conflicts: [], commits: [])
      expect(result.up_to_date?).to be true
      expect(result.success?).to be false
    end

    it 'responds to conflicted?' do
      result = described_class.new(status: :conflicted, changes: [], conflicts: ['conflict'], commits: [])
      expect(result.conflicted?).to be true
      expect(result.success?).to be false
    end
  end

  describe '#sync' do
    context 'when pull_only and push_only are both true' do
      it 'raises ArgumentError' do
        expect do
          orchestrator.sync(pull_only: true, push_only: true)
        end.to raise_error(ArgumentError, 'Cannot use both pull_only and push_only')
      end
    end

    context 'when no remote is configured' do
      before do
        allow(git_adapter).to receive(:remote?).and_return(false)
      end

      it 'raises NoRemoteError' do
        expect { orchestrator.sync }.to raise_error(Eluent::Sync::NoRemoteError)
      end
    end

    context 'when another sync is in progress' do
      it 'raises SyncInProgressError' do
        # Simulate another process holding the lock
        # rubocop:disable RSpec/AnyInstance
        allow_any_instance_of(File).to receive(:flock).with(File::LOCK_EX | File::LOCK_NB).and_return(false)
        # rubocop:enable RSpec/AnyInstance

        expect do
          orchestrator.sync
        end.to raise_error(Eluent::Sync::SyncInProgressError, 'Another sync operation is in progress')
      end
    end

    context 'when local and remote are up to date' do
      let(:commit_hash) { 'abc123def456' }

      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive_messages(remote_head: commit_hash, current_commit: commit_hash)
        allow(sync_state).to receive(:base_commit).and_return(commit_hash)
      end

      it 'returns up_to_date status' do
        result = orchestrator.sync

        expect(result.up_to_date?).to be true
        expect(result.changes).to be_empty
        expect(result.conflicts).to be_empty
      end
    end

    context 'when remote branch is not found' do
      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive(:remote_head).and_return(nil)
      end

      it 'raises NoRemoteError' do
        expect { orchestrator.sync }.to raise_error(Eluent::Sync::NoRemoteError, 'Remote branch not found')
      end
    end

    context 'with push_only mode' do
      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive(:add)
        allow(git_adapter).to receive(:commit)
        allow(git_adapter).to receive(:push)
        allow(git_adapter).to receive_messages(clean?: false, current_commit: 'new_commit')
        allow(repository).to receive(:list_atoms).with(status: 'in_progress').and_return([])
      end

      it 'skips pull/merge and only pushes changes' do
        result = orchestrator.sync(push_only: true)

        expect(git_adapter).not_to have_received(:fetch)
        expect(git_adapter).to have_received(:push)
        expect(result.success?).to be true
      end

      it 'does not commit or push with dry_run' do
        result = orchestrator.sync(push_only: true, dry_run: true)

        expect(git_adapter).not_to have_received(:add)
        expect(git_adapter).not_to have_received(:commit)
        expect(git_adapter).not_to have_received(:push)
        expect(result.success?).to be true
      end
    end

    context 'with successful sync' do
      let(:local_commit) { 'local123' }
      let(:remote_commit) { 'remote456' }
      let(:base_commit) { 'base789' }
      let(:local_atom) { build(:atom, id: 'testrepo-LOCALATOM0000000') }

      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive(:current_commit).and_return(local_commit, 'after_commit')
        allow(git_adapter).to receive_messages(remote_head: remote_commit, merge_base: base_commit,
                                               show_file_at_commit: '', clean?: false)
        allow(git_adapter).to receive(:add)
        allow(git_adapter).to receive(:commit)
        allow(git_adapter).to receive(:push)

        allow(sync_state).to receive_messages(base_commit: nil, update: sync_state)
        allow(sync_state).to receive(:save)

        allow(repository).to receive(:load!)
        allow(repository).to receive(:list_atoms).with(status: 'in_progress').and_return([])

        write_jsonl_records(paths.data_file, [
                              { _type: 'header', repo_name: 'testrepo' },
                              local_atom.to_h
                            ])
      end

      it 'performs full sync workflow' do
        result = orchestrator.sync

        expect(git_adapter).to have_received(:fetch)
        expect(git_adapter).to have_received(:push)
        expect(sync_state).to have_received(:update)
        expect(sync_state).to have_received(:save)
        expect(result.success?).to be true
      end

      it 'does not push changes with pull_only mode' do
        result = orchestrator.sync(pull_only: true)

        expect(git_adapter).to have_received(:fetch)
        expect(git_adapter).not_to have_received(:push)
        expect(result.success?).to be true
      end

      it 'does not write changes to disk with dry_run mode' do
        original_content = File.read(paths.data_file)

        result = orchestrator.sync(dry_run: true)

        expect(File.read(paths.data_file)).to eq(original_content)
        expect(git_adapter).not_to have_received(:push)
        expect(result.success?).to be true
      end

      it 'returns computed changes with dry_run mode' do
        result = orchestrator.sync(dry_run: true)

        expect(result.changes).to be_an(Array)
        expect(result.commits).to be_empty
      end

      it 'does not push when working directory is clean after merge' do
        allow(git_adapter).to receive(:clean?).and_return(true)

        result = orchestrator.sync

        expect(git_adapter).not_to have_received(:push)
        expect(result.success?).to be true
      end
    end

    context 'with merge conflicts' do
      let(:local_commit) { 'local123' }
      let(:remote_commit) { 'remote456' }
      let(:atom_id) { generate(:atom_id) }
      let(:conflict) { { atom_id: atom_id, field: :title, local: 'Local', remote: 'Remote' } }

      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive(:current_commit).and_return(local_commit, 'after_commit')
        allow(git_adapter).to receive_messages(remote_head: remote_commit, merge_base: 'base', show_file_at_commit: '',
                                               clean?: false)
        allow(git_adapter).to receive(:add)
        allow(git_adapter).to receive(:commit)
        allow(git_adapter).to receive(:push)

        allow(sync_state).to receive_messages(base_commit: nil, update: sync_state)
        allow(sync_state).to receive(:save)

        allow(repository).to receive(:load!)
        allow(repository).to receive(:list_atoms).with(status: 'in_progress').and_return([])

        write_jsonl_records(paths.data_file, [{ _type: 'header', repo_name: 'testrepo' }])

        merge_engine = instance_double(Eluent::Sync::MergeEngine)
        merge_result = Eluent::Sync::MergeEngine::MergeResult.new(
          atoms: [],
          bonds: [],
          comments: [],
          conflicts: [conflict]
        )
        allow(merge_engine).to receive(:merge).and_return(merge_result)
        orchestrator.instance_variable_set(:@merge_engine, merge_engine)
      end

      it 'returns conflicted status' do
        result = orchestrator.sync

        expect(result.conflicted?).to be true
        expect(result.conflicts).to include(conflict)
      end
    end

    context 'with rollback on failure' do
      let(:local_commit) { 'local123' }
      let(:remote_commit) { 'remote456' }

      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive_messages(remote_head: remote_commit, current_commit: local_commit,
                                               merge_base: 'base', show_file_at_commit: '', clean?: false)
        allow(git_adapter).to receive(:add)
        allow(git_adapter).to receive(:commit).and_raise(StandardError, 'Commit failed')

        allow(sync_state).to receive(:base_commit).and_return(nil)

        allow(repository).to receive(:load!)
        allow(repository).to receive(:list_atoms).with(status: 'in_progress').and_return([])

        write_jsonl_records(paths.data_file, [
                              { _type: 'header', repo_name: 'testrepo' },
                              { _type: 'atom', id: 'original', title: 'Original' }
                            ])
      end

      it 'restores backup on failure' do
        File.read(paths.data_file)

        expect { orchestrator.sync }.to raise_error(StandardError, 'Commit failed')

        expect(File.read(paths.data_file)).to include('Original')
      end

      it 'cleans up backup file' do
        backup_path = "#{paths.data_file}.backup"

        expect { orchestrator.sync }.to raise_error(StandardError)

        expect(File.exist?(backup_path)).to be false
      end
    end

    context 'with in-progress items warning' do
      let(:local_commit) { 'local123' }
      let(:remote_commit) { 'remote456' }
      let(:in_progress_atom) { build(:atom, :in_progress) }

      before do
        allow(git_adapter).to receive(:fetch)
        allow(git_adapter).to receive(:current_commit).and_return(local_commit, 'after_commit')
        allow(git_adapter).to receive_messages(remote_head: remote_commit, merge_base: 'base', show_file_at_commit: '',
                                               clean?: false)
        allow(git_adapter).to receive(:add)
        allow(git_adapter).to receive(:commit)
        allow(git_adapter).to receive(:push)

        allow(sync_state).to receive_messages(base_commit: nil, update: sync_state)
        allow(sync_state).to receive(:save)

        allow(repository).to receive(:load!)
        allow(repository).to receive(:list_atoms).with(status: 'in_progress').and_return([in_progress_atom])

        write_jsonl_records(paths.data_file, [{ _type: 'header', repo_name: 'testrepo' }])
      end

      it 'warns about in-progress items' do
        allow(orchestrator).to receive(:warn)
        orchestrator.sync
        expect(orchestrator).to have_received(:warn).with(/1 items in progress/)
      end

      it 'proceeds with force flag without warning' do
        allow(orchestrator).to receive(:warn)
        orchestrator.sync(force: true)
        expect(orchestrator).not_to have_received(:warn).with(/in progress/)
      end
    end

    context 'when commit fails with nothing to commit' do
      before do
        allow(git_adapter).to receive(:add)
        allow(git_adapter).to receive(:commit).and_raise(
          Eluent::Sync::GitError.new('nothing to commit', command: 'git commit')
        )
        allow(git_adapter).to receive_messages(remote?: true, clean?: false, current_commit: nil)
        allow(repository).to receive(:list_atoms).with(status: 'in_progress').and_return([])
      end

      it 'handles nothing to commit gracefully' do
        result = orchestrator.sync(push_only: true)

        expect(result.success?).to be true
        expect(result.commits).to be_empty
      end
    end
  end

  describe 'parsing JSONL content' do
    let(:local_commit) { 'local123' }
    let(:remote_commit) { 'remote456' }

    before do
      allow(git_adapter).to receive(:fetch)
      allow(git_adapter).to receive(:current_commit).and_return(local_commit, 'after_commit')
      allow(git_adapter).to receive_messages(remote_head: remote_commit, merge_base: 'base', clean?: true)

      allow(sync_state).to receive_messages(base_commit: nil, update: sync_state)
      allow(sync_state).to receive(:save)

      allow(repository).to receive(:load!)
    end

    context 'with malformed JSON in remote' do
      before do
        # Single line of malformed JSON
        malformed = '{ this is not valid json }'
        allow(git_adapter).to receive(:show_file_at_commit).and_return(malformed)

        write_jsonl_records(paths.data_file, [{ _type: 'header', repo_name: 'testrepo' }])
      end

      it 'warns about skipped records' do
        allow(orchestrator).to receive(:warn)
        orchestrator.sync
        expect(orchestrator).to have_received(:warn).with(/skipping malformed JSON line/).at_least(:once)
      end

      it 'continues processing valid records' do
        allow(orchestrator).to receive(:warn)
        result = orchestrator.sync
        expect(result.success?).to be true
      end
    end

    context 'with multiple skipped records' do
      before do
        # 3 lines of invalid JSON (no trailing newline to avoid extra empty line)
        malformed = "not json 1\nnot json 2\nnot json 3"
        allow(git_adapter).to receive(:show_file_at_commit).and_return(malformed)

        write_jsonl_records(paths.data_file, [{ _type: 'header', repo_name: 'testrepo' }])
      end

      it 'warns about total skipped count' do
        allow(orchestrator).to receive(:warn)
        orchestrator.sync
        expect(orchestrator).to have_received(:warn)
          .with(/3 record\(s\) skipped due to data corruption/).at_least(:once)
      end
    end

    context 'when file not found at commit' do
      before do
        allow(git_adapter).to receive(:show_file_at_commit).and_raise(
          Eluent::Sync::GitError.new('File not found', command: 'git show')
        )

        write_jsonl_records(paths.data_file, [{ _type: 'header', repo_name: 'testrepo' }])
      end

      it 'uses empty state' do
        result = orchestrator.sync
        expect(result.success?).to be true
      end
    end
  end
end

RSpec.describe Eluent::Sync::PullFirstOrchestrator do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }
  let(:git_adapter) { instance_double(Eluent::Sync::GitAdapter) }
  let(:sync_state) { instance_double(Eluent::Sync::SyncState) }
  let(:repository) do
    instance_double(
      Eluent::Storage::JsonlRepository,
      paths: paths,
      repo_name: 'testrepo'
    )
  end

  let(:orchestrator) do
    described_class.new(
      repository: repository,
      git_adapter: git_adapter,
      sync_state: sync_state
    )
  end

  describe '#compute_changes' do
    context 'when atoms are added from remote' do
      let(:local_atom) { build(:atom, id: 'testrepo-LOCAL00000000000') }
      let(:remote_atom) { build(:atom, id: 'testrepo-REMOTE0000000000', title: 'New Remote') }

      it 'reports added changes' do
        local_state = { atoms: [local_atom], bonds: [], comments: [] }
        merge_result = Eluent::Sync::MergeEngine::MergeResult.new(
          atoms: [local_atom, remote_atom],
          bonds: [],
          comments: [],
          conflicts: []
        )

        changes = orchestrator.send(:compute_changes, local_state, merge_result)

        added = changes.find { |c| c[:type] == :added }
        expect(added).not_to be_nil
        expect(added[:id]).to eq(remote_atom.id)
      end
    end

    context 'when atoms are removed' do
      let(:local_atom) { build(:atom, id: 'testrepo-TOBEDELETED0000') }

      it 'reports removed changes' do
        local_state = { atoms: [local_atom], bonds: [], comments: [] }
        merge_result = Eluent::Sync::MergeEngine::MergeResult.new(
          atoms: [],
          bonds: [],
          comments: [],
          conflicts: []
        )

        changes = orchestrator.send(:compute_changes, local_state, merge_result)

        removed = changes.find { |c| c[:type] == :removed }
        expect(removed).not_to be_nil
        expect(removed[:id]).to eq(local_atom.id)
      end
    end

    context 'when atoms are modified' do
      let(:atom_id) { generate(:atom_id) }
      let(:local_atom) { build(:atom, id: atom_id, title: 'Original') }
      let(:merged_atom) { build(:atom, id: atom_id, title: 'Modified') }

      it 'reports modified changes' do
        local_state = { atoms: [local_atom], bonds: [], comments: [] }
        merge_result = Eluent::Sync::MergeEngine::MergeResult.new(
          atoms: [merged_atom],
          bonds: [],
          comments: [],
          conflicts: []
        )

        changes = orchestrator.send(:compute_changes, local_state, merge_result)

        modified = changes.find { |c| c[:type] == :modified }
        expect(modified).not_to be_nil
        expect(modified[:id]).to eq(atom_id)
      end
    end

    context 'when atoms are unchanged' do
      let(:atom) { build(:atom) }

      it 'does not report changes' do
        local_state = { atoms: [atom], bonds: [], comments: [] }
        merge_result = Eluent::Sync::MergeEngine::MergeResult.new(
          atoms: [atom],
          bonds: [],
          comments: [],
          conflicts: []
        )

        changes = orchestrator.send(:compute_changes, local_state, merge_result)

        expect(changes).to be_empty
      end
    end
  end
end

RSpec.describe Eluent::Sync::SyncInProgressError do
  it 'is a subclass of Error' do
    expect(described_class).to be < Eluent::Error
  end
end
