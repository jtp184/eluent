# frozen_string_literal: true

RSpec.describe Eluent::Agents::ExecutionLoop do
  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:executor) { instance_double(Eluent::Agents::AgentExecutor) }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      claude_api_key: 'test-key',
      agent_id: 'test-agent'
    )
  end
  let(:loop) do
    described_class.new(
      repository: repository,
      executor: executor,
      configuration: configuration
    )
  end
  let(:indexer) { instance_double(Eluent::Storage::Indexer) }
  let(:paths) { instance_double(Eluent::Storage::Paths, data_file: '/path/data.jsonl') }

  before do
    allow(repository).to receive_messages(indexer: indexer, paths: paths)
    allow(indexer).to receive(:all_atoms).and_return([])
  end

  describe '#initialize' do
    it 'stores dependencies' do
      expect(loop.send(:repository)).to eq(repository)
      expect(loop.send(:executor)).to eq(executor)
      expect(loop.send(:configuration)).to eq(configuration)
    end
  end

  describe '#run' do
    context 'with no ready work' do
      before do
        blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
        allow(blocking_resolver).to receive(:ready?).and_return(false)
        allow(blocking_resolver).to receive(:clear_cache)
      end

      it 'returns immediately with zero iterations' do
        result = loop.run(max_iterations: 10)

        expect(result.iterations).to eq(0)
        expect(result.processed).to eq(0)
      end
    end

    context 'when find_ready_work raises an exception' do
      before do
        allow(repository).to receive(:indexer).and_raise(StandardError, 'Repository error')
      end

      it 'catches the exception and returns with zero iterations' do
        result = loop.run(max_iterations: 10)

        expect(result.iterations).to eq(0)
        expect(result.processed).to eq(0)
      end
    end

    context 'with ready work' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1') }
      let(:success_result) { Eluent::Agents::ExecutionResult.success(atom: atom) }

      before do
        blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
        allow(blocking_resolver).to receive(:clear_cache)
        allow(blocking_resolver).to receive(:ready?) do |a, **_|
          a == atom
        end

        allow(indexer).to receive(:all_atoms).and_return([atom], [])
        allow(repository).to receive(:update_atom).and_return(atom)
        allow(repository).to receive(:find_atom).with('atom-1').and_return(atom)
        allow(executor).to receive(:execute).with(atom).and_return(success_result)
      end

      it 'processes the atom' do
        result = loop.run(max_iterations: 1)

        expect(result.iterations).to eq(1)
        expect(result.processed).to eq(1)
        expect(executor).to have_received(:execute).with(atom)
      end

      it 'claims the atom before execution' do
        loop.run(max_iterations: 1)

        expect(repository).to have_received(:update_atom) do |updated_atom|
          expect(updated_atom.status).to eq(Eluent::Models::Status[:in_progress])
          expect(updated_atom.assignee).to eq('test-agent')
        end
      end
    end

    context 'with execution failure' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1') }
      let(:failure_result) { Eluent::Agents::ExecutionResult.failure(error: 'API Error', atom: atom) }

      before do
        blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
        allow(blocking_resolver).to receive(:clear_cache)
        allow(blocking_resolver).to receive(:ready?) do |a, **_|
          a == atom
        end

        allow(indexer).to receive(:all_atoms).and_return([atom], [])
        allow(repository).to receive(:update_atom).and_return(atom)
        allow(repository).to receive(:find_atom).with('atom-1').and_return(atom)
        allow(executor).to receive(:execute).with(atom).and_return(failure_result)
      end

      it 'counts as error' do
        result = loop.run(max_iterations: 1)

        expect(result.errors).to eq(1)
        expect(result.success?).to be false
      end
    end

    context 'with max_iterations' do
      let(:atom1) { Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1') }
      let(:atom2) { Eluent::Models::Atom.new(id: 'atom-2', title: 'Task 2') }
      let(:success_result) { Eluent::Agents::ExecutionResult.success(atom: atom1) }

      before do
        blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
        allow(blocking_resolver).to receive(:clear_cache)
        allow(blocking_resolver).to receive(:ready?).and_return(true)

        # Return atoms on repeated calls
        call_count = 0
        allow(indexer).to receive(:all_atoms) do
          call_count += 1
          call_count <= 5 ? [atom1, atom2] : []
        end

        allow(repository).to receive_messages(update_atom: atom1, find_atom: atom1)
        allow(executor).to receive(:execute).and_return(success_result)
      end

      it 'stops after max iterations' do
        result = loop.run(max_iterations: 3)

        expect(result.iterations).to eq(3)
      end
    end

    context 'with on_iteration callback' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1') }
      let(:success_result) { Eluent::Agents::ExecutionResult.success(atom: atom) }

      before do
        blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
        allow(blocking_resolver).to receive(:clear_cache)
        allow(blocking_resolver).to receive(:ready?) do |a, **_|
          a == atom
        end

        allow(indexer).to receive(:all_atoms).and_return([atom], [])
        allow(repository).to receive(:update_atom).and_return(atom)
        allow(repository).to receive(:find_atom).with('atom-1').and_return(atom)
        allow(executor).to receive(:execute).with(atom).and_return(success_result)
      end

      it 'calls callback after each iteration' do
        iterations_seen = []

        loop.run(max_iterations: 1, on_iteration: lambda { |iteration, result|
          iterations_seen << [iteration, result.success]
        })

        expect(iterations_seen).to eq([[0, true]])
      end
    end

    context 'with close reason' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1') }
      let(:success_result) do
        Eluent::Agents::ExecutionResult.success(atom: atom, close_reason: 'Completed successfully')
      end

      before do
        blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
        allow(blocking_resolver).to receive(:clear_cache)
        allow(blocking_resolver).to receive(:ready?) do |a, **_|
          a == atom
        end

        allow(indexer).to receive(:all_atoms).and_return([atom], [])
        allow(repository).to receive(:update_atom).and_return(atom)
        allow(repository).to receive(:find_atom).with('atom-1').and_return(atom)
        allow(repository).to receive(:create_comment)
        allow(executor).to receive(:execute).with(atom).and_return(success_result)
      end

      it 'creates completion comment' do
        loop.run(max_iterations: 1)

        expect(repository).to have_received(:create_comment).with(
          parent_id: 'atom-1',
          author: 'test-agent',
          content: 'Agent completed work: Completed successfully'
        )
      end
    end
  end

  describe '#stop!' do
    it 'sets running to false' do
      loop.stop!
      expect(loop.running?).to be false
    end
  end

  describe '#running?' do
    it 'returns false initially' do
      expect(loop.running?).to be false
    end
  end
end

RSpec.describe Eluent::Agents::LoopResult do
  let(:results) { [Eluent::Agents::ExecutionResult.success(atom: nil)] }
  let(:result) do
    described_class.new(
      iterations: 5,
      processed: 4,
      errors: 1,
      results: results
    )
  end

  describe '#success?' do
    it 'returns false when there are errors' do
      expect(result.success?).to be false
    end

    it 'returns true when no errors' do
      clean_result = described_class.new(iterations: 5, processed: 5, errors: 0, results: [])
      expect(clean_result.success?).to be true
    end
  end

  describe '#summary' do
    it 'returns human-readable summary' do
      expect(result.summary).to eq('Completed 5 iterations: 4 processed, 1 errors')
    end
  end
end

RSpec.describe Eluent::Agents::ClaimOutcome do
  describe '#initialize' do
    it 'defaults optional fields' do
      outcome = described_class.new(success: true)

      expect(outcome.reason).to be_nil
      expect(outcome.local_only).to be false
      expect(outcome.fallback).to be false
      expect(outcome.error).to be_nil
    end

    it 'accepts all fields' do
      outcome = described_class.new(
        success: false,
        reason: 'Already claimed',
        local_only: true,
        fallback: true,
        error: 'Network error'
      )

      expect(outcome.success).to be false
      expect(outcome.reason).to eq('Already claimed')
      expect(outcome.local_only).to be true
      expect(outcome.fallback).to be true
      expect(outcome.error).to eq('Network error')
    end
  end

  describe '#success?' do
    it 'returns true when success is true' do
      expect(described_class.new(success: true).success?).to be true
    end

    it 'returns false when success is false' do
      expect(described_class.new(success: false).success?).to be false
    end
  end

  describe '#failed?' do
    it 'returns false when success is true' do
      expect(described_class.new(success: true).failed?).to be false
    end

    it 'returns true when success is false' do
      expect(described_class.new(success: false).failed?).to be true
    end
  end

  describe '#local_only?' do
    it 'returns local_only value' do
      expect(described_class.new(success: true, local_only: true).local_only?).to be true
      expect(described_class.new(success: true, local_only: false).local_only?).to be false
    end
  end

  describe '#fallback?' do
    it 'returns fallback value' do
      expect(described_class.new(success: true, fallback: true).fallback?).to be true
      expect(described_class.new(success: true, fallback: false).fallback?).to be false
    end
  end
end

# rubocop:disable RSpec/MultipleMemoizedHelpers -- ledger sync integration requires many collaborators
RSpec.describe Eluent::Agents::ExecutionLoop, :ledger_sync do
  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:executor) { instance_double(Eluent::Agents::AgentExecutor) }
  let(:ledger_syncer) { instance_double(Eluent::Sync::LedgerSyncer) }
  let(:ledger_sync_state) { instance_double(Eluent::Sync::LedgerSyncState) }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      claude_api_key: 'test-key',
      agent_id: 'test-agent'
    )
  end
  let(:indexer) { instance_double(Eluent::Storage::Indexer) }
  let(:paths) { instance_double(Eluent::Storage::Paths, data_file: '/path/data.jsonl') }
  let(:atom) { Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1') }

  before do
    allow(repository).to receive_messages(indexer: indexer, paths: paths)
    allow(indexer).to receive(:all_atoms).and_return([])
  end

  describe '#initialize' do
    it 'stores ledger sync dependencies' do
      loop_instance = described_class.new(
        repository: repository,
        executor: executor,
        configuration: configuration,
        ledger_syncer: ledger_syncer,
        ledger_sync_state: ledger_sync_state,
        sync_config: { 'offline_mode' => 'local' }
      )

      expect(loop_instance.send(:ledger_syncer)).to eq(ledger_syncer)
      expect(loop_instance.send(:ledger_sync_state)).to eq(ledger_sync_state)
      expect(loop_instance.send(:sync_config)).to eq({ 'offline_mode' => 'local' })
    end
  end

  describe '#claim_atom' do
    let(:loop_instance) do
      described_class.new(
        repository: repository,
        executor: executor,
        configuration: configuration,
        ledger_syncer: ledger_syncer,
        ledger_sync_state: ledger_sync_state
      )
    end

    context 'when ledger syncer is available' do
      let(:claim_result) do
        Eluent::Sync::LedgerSyncer::ClaimResult.new(
          success: true,
          claimed_by: 'test-agent',
          retries: 0,
          offline_claim: false
        )
      end

      before do
        allow(ledger_syncer).to receive_messages(available?: true, claim_and_push: claim_result)
        allow(repository).to receive(:load!)
      end

      it 'performs atomic claim via ledger syncer' do
        outcome = loop_instance.send(:claim_atom, atom)

        expect(ledger_syncer).to have_received(:claim_and_push)
          .with(atom_id: 'atom-1', agent_id: 'test-agent')
        expect(outcome.success?).to be true
        expect(outcome.local_only?).to be false
      end

      it 'reloads repository after successful claim' do
        loop_instance.send(:claim_atom, atom)

        expect(repository).to have_received(:load!)
      end

      context 'when claim fails' do
        let(:claim_result) do
          Eluent::Sync::LedgerSyncer::ClaimResult.new(
            success: false,
            error: 'Already claimed by other-agent',
            claimed_by: 'other-agent'
          )
        end

        it 'returns failure outcome with reason' do
          outcome = loop_instance.send(:claim_atom, atom)

          expect(outcome.success?).to be false
          expect(outcome.reason).to eq('Already claimed by other-agent')
        end
      end
    end

    context 'when ledger syncer is not available' do
      before do
        allow(ledger_syncer).to receive(:available?).and_return(false)
        allow(repository).to receive(:update_atom).and_return(atom)
      end

      it 'falls back to local claiming' do
        outcome = loop_instance.send(:claim_atom, atom)

        expect(outcome.success?).to be true
        expect(outcome.local_only?).to be true
      end

      it 'updates atom status locally' do
        loop_instance.send(:claim_atom, atom)

        expect(repository).to have_received(:update_atom) do |updated_atom|
          expect(updated_atom.status).to eq(Eluent::Models::Status[:in_progress])
          expect(updated_atom.assignee).to eq('test-agent')
        end
      end
    end

    context 'when atom is already claimed by another agent' do
      let(:loop_instance) do
        described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration
        )
      end
      let(:claimed_atom) do
        Eluent::Models::Atom.new(
          id: 'atom-1',
          title: 'Task 1',
          status: :in_progress,
          assignee: 'other-agent'
        )
      end

      it 'returns failure with reason' do
        outcome = loop_instance.send(:claim_atom, claimed_atom)

        expect(outcome.success?).to be false
        expect(outcome.reason).to eq('Already claimed by other-agent')
      end
    end

    context 'when atom is in_progress with nil assignee (edge case)' do
      let(:loop_instance) do
        described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration
        )
      end
      let(:orphaned_atom) do
        Eluent::Models::Atom.new(
          id: 'atom-1',
          title: 'Task 1',
          status: :in_progress,
          assignee: nil
        )
      end

      it 'returns failure with generic owner message' do
        outcome = loop_instance.send(:claim_atom, orphaned_atom)

        expect(outcome.success?).to be false
        expect(outcome.reason).to eq('Already claimed by another agent')
      end
    end

    context 'when repository.load! fails after successful remote claim' do
      let(:claim_result) do
        Eluent::Sync::LedgerSyncer::ClaimResult.new(
          success: true,
          claimed_by: 'test-agent',
          offline_claim: false
        )
      end

      before do
        allow(ledger_syncer).to receive_messages(available?: true, claim_and_push: claim_result)
        allow(repository).to receive(:load!).and_raise(StandardError, 'Repository corrupted')
      end

      it 'still returns success (claim was committed remotely)' do
        outcome = loop_instance.send(:claim_atom, atom)

        expect(outcome.success?).to be true
        expect(outcome.local_only?).to be false
      end
    end

    context 'when ledger sync fails with LedgerSyncerError' do
      let(:loop_instance) do
        described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration,
          ledger_syncer: ledger_syncer,
          ledger_sync_state: ledger_sync_state,
          sync_config: { 'offline_mode' => 'local' }
        )
      end

      before do
        allow(ledger_syncer).to receive(:available?).and_return(true)
        allow(ledger_syncer).to receive(:claim_and_push)
          .and_raise(Eluent::Sync::LedgerSyncerError, 'Network timeout')
        allow(repository).to receive(:update_atom).and_return(atom)
        allow(ledger_sync_state).to receive_messages(exists?: false, load: ledger_sync_state,
                                                     record_offline_claim: ledger_sync_state, save: ledger_sync_state)
      end

      it 'falls back to local claiming with offline_mode local' do
        outcome = loop_instance.send(:claim_atom, atom)

        expect(outcome.success?).to be true
        expect(outcome.local_only?).to be true
        expect(outcome.fallback?).to be true
        expect(outcome.error).to eq('Network timeout')
      end

      it 'records offline claim for later reconciliation using injected clock' do
        frozen_time = Time.new(2026, 1, 20, 12, 0, 0, '+00:00')
        clock = class_double(Time, now: frozen_time)
        loop_with_clock = described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration,
          ledger_syncer: ledger_syncer,
          ledger_sync_state: ledger_sync_state,
          sync_config: { 'offline_mode' => 'local' },
          clock: clock
        )

        loop_with_clock.send(:claim_atom, atom)

        expect(ledger_sync_state).to have_received(:record_offline_claim)
          .with(atom_id: 'atom-1', agent_id: 'test-agent', claimed_at: frozen_time)
        expect(ledger_sync_state).to have_received(:save)
      end

      context 'with offline_mode fail' do
        let(:loop_instance) do
          described_class.new(
            repository: repository,
            executor: executor,
            configuration: configuration,
            ledger_syncer: ledger_syncer,
            sync_config: { 'offline_mode' => 'fail' }
          )
        end

        it 'returns failure without fallback' do
          outcome = loop_instance.send(:claim_atom, atom)

          expect(outcome.success?).to be false
          expect(outcome.reason).to eq('Network timeout')
        end
      end
    end

    context 'when available? raises WorktreeError' do
      let(:loop_instance) do
        described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration,
          ledger_syncer: ledger_syncer,
          ledger_sync_state: ledger_sync_state,
          sync_config: { 'offline_mode' => 'local' }
        )
      end

      before do
        allow(ledger_syncer).to receive(:available?)
          .and_raise(Eluent::Sync::WorktreeError.new('Worktree corrupted'))
        allow(repository).to receive(:update_atom).and_return(atom)
        allow(ledger_sync_state).to receive_messages(exists?: false, load: ledger_sync_state,
                                                     record_offline_claim: ledger_sync_state, save: ledger_sync_state)
      end

      it 'treats corrupted worktree as unavailable and claims locally' do
        outcome = loop_instance.send(:claim_atom, atom)

        expect(outcome.success?).to be true
        expect(outcome.local_only?).to be true
        # Not fallback because availability check failure means syncer is simply unavailable,
        # not that we attempted sync and it failed
      end
    end

    context 'when available? raises GitError' do
      let(:loop_instance) do
        described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration,
          ledger_syncer: ledger_syncer,
          sync_config: { 'offline_mode' => 'local' }
        )
      end

      before do
        allow(ledger_syncer).to receive(:available?)
          .and_raise(Eluent::Sync::GitError.new('Git command failed'))
        allow(repository).to receive(:update_atom).and_return(atom)
      end

      it 'treats git failure as unavailable and claims locally' do
        outcome = loop_instance.send(:claim_atom, atom)

        expect(outcome.success?).to be true
        expect(outcome.local_only?).to be true
        # Not fallback because availability check failure means syncer is simply unavailable
      end
    end
  end

  describe '#release_claim_on_failure' do
    let(:loop_instance) do
      described_class.new(
        repository: repository,
        executor: executor,
        configuration: configuration,
        ledger_syncer: ledger_syncer
      )
    end
    let(:release_result) do
      Eluent::Sync::LedgerSyncer::ClaimResult.new(success: true)
    end
    let(:claimed_atom) do
      Eluent::Models::Atom.new(
        id: 'atom-1',
        title: 'Task 1',
        status: :in_progress,
        assignee: 'test-agent'
      )
    end

    before do
      allow(repository).to receive(:find_atom).with('atom-1').and_return(claimed_atom)
      allow(repository).to receive(:update_atom).and_return(claimed_atom)
    end

    context 'when ledger syncer is available' do
      before do
        allow(ledger_syncer).to receive_messages(available?: true, release_claim: release_result)
      end

      it 'releases via ledger syncer and locally' do
        loop_instance.send(:release_claim_on_failure, atom)

        expect(ledger_syncer).to have_received(:release_claim).with(atom_id: 'atom-1')
      end
    end

    context 'when ledger syncer is not available' do
      before do
        allow(ledger_syncer).to receive(:available?).and_return(false)
      end

      it 'releases locally only' do
        loop_instance.send(:release_claim_on_failure, atom)

        expect(repository).to have_received(:update_atom) do |updated_atom|
          expect(updated_atom.status).to eq(Eluent::Models::Status[:open])
          expect(updated_atom.assignee).to be_nil
        end
      end
    end

    context 'when ledger release fails' do
      before do
        allow(ledger_syncer).to receive(:available?).and_return(true)
        allow(ledger_syncer).to receive(:release_claim)
          .and_raise(Eluent::Sync::LedgerSyncerError, 'Push failed')
      end

      it 'still releases locally' do
        loop_instance.send(:release_claim_on_failure, atom)

        expect(repository).to have_received(:update_atom)
      end
    end

    context 'when available? raises WorktreeError' do
      before do
        allow(ledger_syncer).to receive(:available?)
          .and_raise(Eluent::Sync::WorktreeError.new('Worktree corrupted'))
      end

      it 'still releases locally' do
        loop_instance.send(:release_claim_on_failure, atom)

        expect(repository).to have_received(:update_atom)
      end
    end
  end

  describe '#sync_after_work' do
    let(:loop_instance) do
      described_class.new(
        repository: repository,
        executor: executor,
        configuration: configuration,
        ledger_syncer: ledger_syncer
      )
    end

    context 'when work succeeded and ledger syncer is available' do
      let(:push_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: true, changes_applied: 1) }
      let(:sync_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: true, changes_applied: 1) }

      before do
        allow(ledger_syncer).to receive_messages(available?: true, push_ledger: push_result, sync_to_main: sync_result)
      end

      it 'pushes ledger and syncs to main' do
        loop_instance.send(:sync_after_work, true)

        expect(ledger_syncer).to have_received(:push_ledger)
        expect(ledger_syncer).to have_received(:sync_to_main)
      end
    end

    context 'when work failed' do
      before do
        allow(ledger_syncer).to receive(:available?).and_return(true)
      end

      it 'does not sync ledger' do
        loop_instance.send(:sync_after_work, false)

        expect(ledger_syncer).not_to have_received(:push_ledger) if ledger_syncer.respond_to?(:push_ledger)
      end
    end

    context 'when ledger push fails' do
      let(:push_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: false, error: 'Push rejected') }

      before do
        allow(ledger_syncer).to receive_messages(available?: true, push_ledger: push_result)
      end

      it 'does not call sync_to_main' do
        loop_instance.send(:sync_after_work, true)

        expect(ledger_syncer).not_to have_received(:sync_to_main) if ledger_syncer.respond_to?(:sync_to_main)
      end
    end

    context 'when push succeeds but sync_to_main fails' do
      let(:push_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: true, changes_applied: 1) }
      let(:sync_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: false, error: 'Merge conflict') }

      before do
        allow(ledger_syncer).to receive_messages(available?: true, push_ledger: push_result, sync_to_main: sync_result)
      end

      it 'completes without raising (logs warning)' do
        expect { loop_instance.send(:sync_after_work, true) }.not_to raise_error
        expect(ledger_syncer).to have_received(:sync_to_main)
      end
    end
  end

  describe '#record_offline_claim' do
    let(:loop_instance) do
      described_class.new(
        repository: repository,
        executor: executor,
        configuration: configuration,
        ledger_syncer: ledger_syncer,
        ledger_sync_state: ledger_sync_state,
        sync_config: { 'offline_mode' => 'local' }
      )
    end

    context 'when ledger_sync_state.save fails' do
      before do
        allow(ledger_sync_state).to receive_messages(exists?: false, load: ledger_sync_state,
                                                     record_offline_claim: ledger_sync_state)
        allow(ledger_sync_state).to receive(:save).and_raise(Eluent::Sync::LedgerSyncStateError, 'Disk full')
      end

      it 'catches the error and does not propagate' do
        expect { loop_instance.send(:record_offline_claim, atom) }.not_to raise_error
      end
    end

    context 'when ledger_sync_state is nil' do
      let(:loop_instance) do
        described_class.new(
          repository: repository,
          executor: executor,
          configuration: configuration,
          ledger_syncer: ledger_syncer,
          ledger_sync_state: nil
        )
      end

      it 'returns early without error' do
        expect { loop_instance.send(:record_offline_claim, atom) }.not_to raise_error
      end
    end
  end

  describe '#run' do
    let(:success_result) { Eluent::Agents::ExecutionResult.success(atom: atom) }
    let(:claim_result) do
      Eluent::Sync::LedgerSyncer::ClaimResult.new(
        success: true,
        claimed_by: 'test-agent',
        offline_claim: false
      )
    end
    let(:push_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: true, changes_applied: 1) }
    let(:sync_result) { Eluent::Sync::LedgerSyncer::SyncResult.new(success: true, changes_applied: 1) }

    let(:loop_instance) do
      described_class.new(
        repository: repository,
        executor: executor,
        configuration: configuration,
        ledger_syncer: ledger_syncer
      )
    end

    before do
      blocking_resolver = instance_double(Eluent::Graph::BlockingResolver)
      allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(blocking_resolver)
      allow(blocking_resolver).to receive(:clear_cache)
      allow(blocking_resolver).to receive(:ready?).and_return(true)

      allow(indexer).to receive(:all_atoms).and_return([atom], [])
      allow(repository).to receive_messages(update_atom: atom, load!: true, find_atom: atom)
      allow(executor).to receive(:execute).with(atom).and_return(success_result)

      allow(ledger_syncer).to receive_messages(available?: true, claim_and_push: claim_result,
                                               push_ledger: push_result, sync_to_main: sync_result)
    end

    it 'claims via ledger syncer, executes, and syncs after work' do
      result = loop_instance.run(max_iterations: 1)

      expect(result.processed).to eq(1)
      expect(ledger_syncer).to have_received(:claim_and_push)
      expect(executor).to have_received(:execute).with(atom)
      expect(ledger_syncer).to have_received(:push_ledger)
      expect(ledger_syncer).to have_received(:sync_to_main)
    end
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
