# frozen_string_literal: true

RSpec.describe Eluent::Compaction::Restorer do
  let(:root_path) { Dir.mktmpdir }
  let(:repository) do
    repo = Eluent::Storage::JsonlRepository.new(root_path)
    repo.init(repo_name: 'testrepo')
    repo
  end

  after { FileUtils.rm_rf(root_path) }

  # Using double instead of instance_double because run_git is private
  let(:git_adapter) { double('GitAdapter') }
  let(:restorer) { described_class.new(repository: repository, git_adapter: git_adapter) }

  describe '#restore' do
    let!(:compacted_atom) do
      atom = repository.create_atom(
        title: 'Compacted Item',
        description: 'Short summary...',
        status: :closed,
        metadata: {
          'compaction_tier' => 1,
          'compacted_at' => '2025-01-01T00:00:00Z',
          'original_description_length' => 500
        }
      )
      atom
    end

    let(:historical_content) do
      <<~JSONL
        {"_type":"header","repo_name":"testrepo"}
        {"_type":"atom","id":"#{compacted_atom.id}","title":"Compacted Item","description":"This is the full original description that was much longer before compaction.","status":"closed"}
        {"_type":"comment","id":"#{compacted_atom.id}-c1","parent_id":"#{compacted_atom.id}","author":"alice","content":"First original comment"}
        {"_type":"comment","id":"#{compacted_atom.id}-c2","parent_id":"#{compacted_atom.id}","author":"bob","content":"Second original comment"}
      JSONL
    end

    before do
      allow(git_adapter).to receive(:run_git) do |*args|
        case args.first
        when 'log'
          { success: true, output: "abc123\ndef456\n" }
        when 'show'
          { success: true, output: historical_content }
        else
          { success: false, output: '' }
        end
      end
    end

    it 'restores description from git history' do
      result = restorer.restore(compacted_atom.id)

      expect(result).to be_a(Eluent::Compaction::RestorationResult)

      updated = repository.find_atom(compacted_atom.id)
      expect(updated.description).to include('full original description')
    end

    it 'clears compaction metadata' do
      restorer.restore(compacted_atom.id)

      updated = repository.find_atom(compacted_atom.id)
      expect(updated.metadata['compaction_tier']).to be_nil
      expect(updated.metadata['compacted_at']).to be_nil
    end

    it 'sets restored metadata' do
      restorer.restore(compacted_atom.id)

      updated = repository.find_atom(compacted_atom.id)
      expect(updated.metadata['restored_at']).not_to be_nil
      expect(updated.metadata['restored_from_commit']).to eq('abc123')
    end

    it 'raises error when atom not found' do
      expect { restorer.restore('nonexistent') }
        .to raise_error(Eluent::Registry::IdNotFoundError)
    end

    it 'raises error when atom not compacted' do
      non_compacted = repository.create_atom(title: 'Not Compacted')

      expect { restorer.restore(non_compacted.id) }
        .to raise_error(Eluent::Compaction::RestoreError, /not been compacted/)
    end

    it 'raises error when historical version not found' do
      allow(git_adapter).to receive(:run_git) do |*args|
        case args.first
        when 'log'
          { success: true, output: '' }
        else
          { success: false, output: '' }
        end
      end

      expect { restorer.restore(compacted_atom.id) }
        .to raise_error(Eluent::Compaction::RestoreError, /Could not find/)
    end
  end

  describe '#can_restore?' do
    let!(:compacted_atom) do
      repository.create_atom(
        title: 'Test',
        status: :closed,
        metadata: { 'compaction_tier' => 1, 'compacted_at' => '2025-01-01T00:00:00Z' }
      )
    end

    it 'returns false for non-compacted atoms' do
      non_compacted = repository.create_atom(title: 'Not Compacted')
      expect(restorer.can_restore?(non_compacted.id)).to be false
    end

    it 'returns false for non-existent atoms' do
      expect(restorer.can_restore?('nonexistent')).to be false
    end
  end

  describe '#preview_restore' do
    let!(:compacted_atom) do
      repository.create_atom(
        title: 'Preview Test',
        description: 'Short',
        status: :closed,
        metadata: { 'compaction_tier' => 1, 'compacted_at' => '2025-01-01T00:00:00Z' }
      )
    end

    let(:historical_content) do
      <<~JSONL
        {"_type":"atom","id":"#{compacted_atom.id}","title":"Preview Test","description":"Much longer original description here"}
        {"_type":"comment","id":"c1","parent_id":"#{compacted_atom.id}","author":"alice","content":"Comment"}
      JSONL
    end

    before do
      allow(git_adapter).to receive(:run_git) do |*args|
        case args.first
        when 'log'
          { success: true, output: "abc123\n" }
        when 'show'
          { success: true, output: historical_content }
        else
          { success: false, output: '' }
        end
      end
    end

    it 'returns preview without modifying atom' do
      preview = restorer.preview_restore(compacted_atom.id)

      expect(preview[:atom_id]).to eq(compacted_atom.id)
      expect(preview[:current][:compaction_tier]).to eq(1)
      expect(preview[:restored][:description_length]).to be > preview[:current][:description_length]

      # Atom should not be modified
      unchanged = repository.find_atom(compacted_atom.id)
      expect(unchanged.description).to eq('Short')
    end
  end

  describe Eluent::Compaction::RestorationResult do
    let(:result) do
      described_class.new(
        atom_id: 'test-123',
        restored_description_length: 500,
        restored_comment_count: 3
      )
    end

    it 'stores restoration details' do
      expect(result.atom_id).to eq('test-123')
      expect(result.restored_description_length).to eq(500)
      expect(result.restored_comment_count).to eq(3)
    end

    it 'serializes to hash' do
      hash = result.to_h
      expect(hash).to include(
        atom_id: 'test-123',
        restored_description_length: 500,
        restored_comment_count: 3
      )
    end
  end
end
