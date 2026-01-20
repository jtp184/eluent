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
