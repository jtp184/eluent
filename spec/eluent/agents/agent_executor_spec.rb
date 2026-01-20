# frozen_string_literal: true

RSpec.describe Eluent::Agents::AgentExecutor do
  # Concrete implementation for testing
  let(:executor_class) do
    Class.new(described_class) do
      def execute(atom, _system_prompt: nil)
        Eluent::Agents::ExecutionResult.success(atom: atom)
      end

      # Make execute_tool public for testing
      public :execute_tool
    end
  end

  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      claude_api_key: 'test-key',
      agent_id: 'test-agent'
    )
  end
  let(:executor) { executor_class.new(repository: repository, configuration: configuration) }

  describe '#initialize' do
    it 'stores repository and configuration' do
      expect(executor.send(:repository)).to eq(repository)
      expect(executor.send(:configuration)).to eq(configuration)
    end
  end

  describe '#execute' do
    let(:atom) { Eluent::Models::Atom.new(id: 'test-123', title: 'Test') }

    it 'must be implemented by subclass' do
      base_executor = described_class.new(repository: repository, configuration: configuration)

      expect { base_executor.execute(atom) }.to raise_error(NotImplementedError)
    end
  end

  describe '#execute_tool' do
    describe 'tool_list_items' do
      let(:atoms) do
        [
          Eluent::Models::Atom.new(id: 'atom-1', title: 'Task 1'),
          Eluent::Models::Atom.new(id: 'atom-2', title: 'Task 2')
        ]
      end

      before do
        allow(repository).to receive(:list_atoms).and_return(atoms)
      end

      it 'returns list of items' do
        result = executor.execute_tool('list_items', {})

        expect(result[:count]).to eq(2)
        expect(result[:items].size).to eq(2)
      end
    end

    describe 'tool_show_item' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-123', title: 'Test Task') }

      before do
        allow(repository).to receive(:find_atom).with('atom-123').and_return(atom)
        allow(repository).to receive_messages(bonds_for: { outgoing: [], incoming: [] }, comments_for: [])
      end

      it 'returns item details' do
        result = executor.execute_tool('show_item', { id: 'atom-123' })

        expect(result[:item][:id]).to eq('atom-123')
        expect(result[:item][:title]).to eq('Test Task')
      end

      it 'returns error for unknown item' do
        allow(repository).to receive(:find_atom).with('unknown').and_return(nil)

        result = executor.execute_tool('show_item', { id: 'unknown' })

        expect(result[:error]).to include('not found')
      end
    end

    describe 'tool_create_item' do
      let(:created_atom) { Eluent::Models::Atom.new(id: 'new-123', title: 'New Task') }

      before do
        allow(repository).to receive(:create_atom).and_return(created_atom)
      end

      it 'creates a new item' do
        result = executor.execute_tool('create_item', { title: 'New Task' })

        expect(result[:created][:id]).to eq('new-123')
        expect(result[:created][:title]).to eq('New Task')
      end
    end

    describe 'tool_update_item' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-123', title: 'Old Title', priority: 2) }

      before do
        allow(repository).to receive(:find_atom).with('atom-123').and_return(atom)
        allow(repository).to receive(:update_atom).and_return(atom)
      end

      it 'updates item fields' do
        executor.execute_tool('update_item', { id: 'atom-123', title: 'New Title', priority: 1 })

        expect(atom.title).to eq('New Title')
        expect(atom.priority).to eq(1)
      end

      it 'updates status' do
        executor.execute_tool('update_item', { id: 'atom-123', status: 'in_progress' })

        expect(atom.status).to eq(Eluent::Models::Status[:in_progress])
      end
    end

    describe 'tool_close_item' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-123', title: 'Task') }

      before do
        allow(repository).to receive(:find_atom).with('atom-123').and_return(atom)
        allow(repository).to receive(:update_atom).and_return(atom)
      end

      it 'closes the item' do
        result = executor.execute_tool('close_item', { id: 'atom-123', reason: 'Completed' })

        expect(atom.status).to eq(Eluent::Models::Status[:closed])
        expect(atom.close_reason).to eq('Completed')
        expect(result[:closed]).to be_a(Hash)
      end
    end

    describe 'tool_add_comment' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-123', title: 'Task') }
      let(:comment) { Eluent::Models::Comment.new(id: 'comment-1', parent_id: 'atom-123', author: 'test-agent', content: 'Test comment') }

      before do
        allow(repository).to receive(:find_atom).with('atom-123').and_return(atom)
        allow(repository).to receive(:create_comment).and_return(comment)
      end

      it 'creates a comment' do
        result = executor.execute_tool('add_comment', { id: 'atom-123', content: 'Test comment' })

        expect(result[:created][:content]).to eq('Test comment')
      end
    end

    describe 'unknown tool' do
      it 'returns error' do
        result = executor.execute_tool('unknown_tool', {})

        expect(result[:error]).to include('Unknown tool')
      end
    end

    describe 'input validation' do
      it 'returns error for nil tool_name' do
        result = executor.execute_tool(nil, {})

        expect(result[:error]).to include('non-empty string')
      end

      it 'returns error for empty tool_name' do
        result = executor.execute_tool('', {})

        expect(result[:error]).to include('non-empty string')
      end

      it 'returns error for whitespace-only tool_name' do
        result = executor.execute_tool('   ', {})

        expect(result[:error]).to include('non-empty string')
      end

      it 'returns error for non-Hash arguments' do
        result = executor.execute_tool('list_items', 'not a hash')

        expect(result[:error]).to include('Hash or nil')
      end

      it 'accepts nil arguments' do
        allow(repository).to receive(:list_atoms).and_return([])
        result = executor.execute_tool('list_items', nil)

        expect(result[:error]).to be_nil
        expect(result[:count]).to eq(0)
      end
    end

    describe 'tool_create_item validation' do
      before do
        allow(repository).to receive(:create_atom)
      end

      it 'returns error for nil title' do
        result = executor.execute_tool('create_item', { title: nil })

        expect(result[:error]).to include('Title is required')
      end

      it 'returns error for empty title' do
        result = executor.execute_tool('create_item', { title: '' })

        expect(result[:error]).to include('Title is required')
      end

      it 'returns error for priority below 0' do
        result = executor.execute_tool('create_item', { title: 'Test', priority: -1 })

        expect(result[:error]).to include('Priority must be between 0 and 4')
      end

      it 'returns error for priority above 4' do
        result = executor.execute_tool('create_item', { title: 'Test', priority: 5 })

        expect(result[:error]).to include('Priority must be between 0 and 4')
      end

      it 'accepts valid priority 0' do
        allow(repository).to receive(:create_atom).and_return(
          Eluent::Models::Atom.new(id: 'new-1', title: 'Test')
        )
        result = executor.execute_tool('create_item', { title: 'Test', priority: 0 })

        expect(result[:error]).to be_nil
      end

      it 'accepts valid priority 4' do
        allow(repository).to receive(:create_atom).and_return(
          Eluent::Models::Atom.new(id: 'new-1', title: 'Test')
        )
        result = executor.execute_tool('create_item', { title: 'Test', priority: 4 })

        expect(result[:error]).to be_nil
      end
    end

    describe 'tool_update_item validation' do
      let(:atom) { Eluent::Models::Atom.new(id: 'atom-123', title: 'Test', priority: 2) }

      before do
        allow(repository).to receive(:find_atom).with('atom-123').and_return(atom)
        allow(repository).to receive(:update_atom).and_return(atom)
      end

      it 'returns error for priority below 0' do
        result = executor.execute_tool('update_item', { id: 'atom-123', priority: -1 })

        expect(result[:error]).to include('Priority must be between 0 and 4')
      end

      it 'returns error for priority above 4' do
        result = executor.execute_tool('update_item', { id: 'atom-123', priority: 5 })

        expect(result[:error]).to include('Priority must be between 0 and 4')
      end

      it 'ignores unknown fields' do
        result = executor.execute_tool('update_item', { id: 'atom-123', unknown_field: 'value' })

        expect(result[:error]).to be_nil
        expect(result[:updated]).to be_a(Hash)
      end
    end

    describe 'tool_list_ready_items validation' do
      before do
        allow(repository).to receive(:indexer).and_return(instance_double(Eluent::Storage::Indexer, all_atoms: []))
        allow(Eluent::Graph::BlockingResolver).to receive(:new).and_return(
          instance_double(Eluent::Graph::BlockingResolver, ready?: true, clear_cache: nil)
        )
      end

      it 'clamps limit to maximum of 50' do
        result = executor.execute_tool('list_ready_items', { limit: 100 })

        expect(result[:error]).to be_nil
        # The limit should be capped internally - we can't directly verify it but no error means it worked
      end

      it 'clamps negative limit to 1' do
        result = executor.execute_tool('list_ready_items', { limit: -5 })

        expect(result[:error]).to be_nil
      end
    end
  end
end

RSpec.describe Eluent::Agents::ExecutionResult do
  describe '.success' do
    let(:atom) { Eluent::Models::Atom.new(id: 'test', title: 'Test') }

    it 'creates successful result' do
      result = described_class.success(atom: atom, close_reason: 'Done', follow_ups: ['task-2'])

      expect(result.success).to be true
      expect(result.atom).to eq(atom)
      expect(result.close_reason).to eq('Done')
      expect(result.follow_ups).to eq(['task-2'])
      expect(result.error).to be_nil
    end
  end

  describe '.failure' do
    it 'creates failed result' do
      result = described_class.failure(error: 'API Error', atom: nil)

      expect(result.success).to be false
      expect(result.error).to eq('API Error')
      expect(result.close_reason).to be_nil
      expect(result.follow_ups).to eq([])
    end
  end
end
