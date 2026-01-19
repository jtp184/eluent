# frozen_string_literal: true

RSpec.describe Eluent::Compaction::Compactor do
  let(:root_path) { Dir.mktmpdir }
  let(:repository) do
    repo = Eluent::Storage::JsonlRepository.new(root_path)
    repo.init(repo_name: 'testrepo')
    repo
  end

  after { FileUtils.rm_rf(root_path) }

  let(:compactor) { described_class.new(repository: repository) }

  describe '#find_candidates' do
    let(:old_time) { Time.now.utc - (60 * 24 * 60 * 60) } # 60 days ago

    let!(:old_closed_atom) do
      Timecop.freeze(old_time) do
        repository.create_atom(title: 'Old Closed', status: :closed)
      end
    end

    let!(:recent_closed_atom) do
      repository.create_atom(title: 'Recent Closed', status: :closed)
    end

    let!(:old_open_atom) do
      Timecop.freeze(old_time) do
        repository.create_atom(title: 'Old Open', status: :open)
      end
    end

    it 'returns closed atoms older than tier threshold' do
      candidates = compactor.find_candidates(tier: 1)
      expect(candidates.map(&:id)).to include(old_closed_atom.id)
    end

    it 'excludes recently closed atoms' do
      candidates = compactor.find_candidates(tier: 1)
      expect(candidates.map(&:id)).not_to include(recent_closed_atom.id)
    end

    it 'excludes open atoms' do
      candidates = compactor.find_candidates(tier: 1)
      expect(candidates.map(&:id)).not_to include(old_open_atom.id)
    end

    it 'excludes already compacted atoms' do
      Timecop.freeze(old_time) do
        old_closed_atom.metadata['compaction_tier'] = 1
        repository.update_atom(old_closed_atom)
      end

      candidates = compactor.find_candidates(tier: 1)
      expect(candidates.map(&:id)).not_to include(old_closed_atom.id)
    end

    it 'includes tier 1 compacted atoms for tier 2' do
      very_old_time = Time.now.utc - (100 * 24 * 60 * 60) # 100 days
      Timecop.freeze(very_old_time) do
        old_closed_atom.metadata['compaction_tier'] = 1
        repository.update_atom(old_closed_atom)
      end

      candidates = compactor.find_candidates(tier: 2)
      expect(candidates.map(&:id)).to include(old_closed_atom.id)
    end

    it 'raises error for unknown tier' do
      expect { compactor.find_candidates(tier: 99) }
        .to raise_error(Eluent::Compaction::CompactionError)
    end
  end

  describe '#compact' do
    let(:old_time) { Time.now.utc - (60 * 24 * 60 * 60) }

    let!(:atom) do
      Timecop.freeze(old_time) do
        repository.create_atom(
          title: 'Test',
          description: 'A' * 600,
          status: :closed
        )
      end
    end

    before do
      Timecop.freeze(old_time) do
        repository.create_comment(parent_id: atom.id, author: 'alice', content: 'Comment 1')
        repository.create_comment(parent_id: atom.id, author: 'bob', content: 'Comment 2')
      end
    end

    it 'returns CompactionResult' do
      result = compactor.compact(atom.id, tier: 1)
      expect(result).to be_a(Eluent::Compaction::CompactionResult)
    end

    it 'updates atom description with summary' do
      compactor.compact(atom.id, tier: 1)

      updated = repository.find_atom(atom.id)
      expect(updated.description.length).to be < 600
    end

    it 'sets compaction_tier in metadata' do
      compactor.compact(atom.id, tier: 1)

      updated = repository.find_atom(atom.id)
      expect(updated.metadata['compaction_tier']).to eq(1)
    end

    it 'replaces comments with summary for tier 1' do
      compactor.compact(atom.id, tier: 1)

      comments = repository.comments_for(atom.id)
      expect(comments.size).to eq(1)
      expect(comments.first.author).to eq('system')
    end

    it 'removes all comments for tier 2' do
      very_old_time = Time.now.utc - (100 * 24 * 60 * 60)
      Timecop.freeze(very_old_time) do
        atom.metadata['compaction_tier'] = 1
        repository.update_atom(atom)
      end

      compactor.compact(atom.id, tier: 2)

      comments = repository.comments_for(atom.id)
      expect(comments).to be_empty
    end

    it 'raises error when atom not found' do
      expect { compactor.compact('nonexistent', tier: 1) }
        .to raise_error(Eluent::Registry::IdNotFoundError)
    end
  end

  describe '#compact_all' do
    let(:old_time) { Time.now.utc - (60 * 24 * 60 * 60) }

    before do
      Timecop.freeze(old_time) do
        3.times do |i|
          repository.create_atom(title: "Atom #{i}", status: :closed)
        end
      end
    end

    context 'with preview: false' do
      it 'compacts all candidates' do
        result = compactor.compact_all(tier: 1)

        expect(result).to be_a(Eluent::Compaction::CompactionBatchResult)
        expect(result.success_count).to eq(3)
      end
    end

    context 'with preview: true' do
      it 'returns preview without compacting' do
        result = compactor.compact_all(tier: 1, preview: true)

        expect(result).to be_a(Hash)
        expect(result[:candidate_count]).to eq(3)

        # Atoms should not be compacted
        repository.all_atoms.each do |atom|
          expect(atom.metadata['compaction_tier']).to be_nil
        end
      end
    end
  end

  describe '#preview' do
    let(:old_time) { Time.now.utc - (60 * 24 * 60 * 60) }

    let!(:atom) do
      Timecop.freeze(old_time) do
        a = repository.create_atom(title: 'Test', description: 'A' * 100, status: :closed)
        repository.create_comment(parent_id: a.id, author: 'alice', content: 'Comment')
        a
      end
    end

    it 'returns preview hash without modifying atom' do
      preview = compactor.preview(atom.id, tier: 1)

      expect(preview[:atom_id]).to eq(atom.id)
      expect(preview[:current][:description_length]).to eq(100)
      expect(preview[:current][:comment_count]).to eq(1)

      # Atom should not be modified
      unchanged = repository.find_atom(atom.id)
      expect(unchanged.metadata['compaction_tier']).to be_nil
    end
  end

  describe Eluent::Compaction::CompactionResult do
    it 'is successful when no error' do
      result = described_class.new(atom_id: 'test', tier: 1, summary: {})
      expect(result).to be_success
    end

    it 'is not successful when error present' do
      result = described_class.new(atom_id: 'test', tier: 1, error: 'Something went wrong')
      expect(result).not_to be_success
    end
  end

  describe Eluent::Compaction::CompactionBatchResult do
    let(:results) do
      [
        Eluent::Compaction::CompactionResult.new(atom_id: 'a1', tier: 1, summary: {}),
        Eluent::Compaction::CompactionResult.new(atom_id: 'a2', tier: 1, summary: {}),
        Eluent::Compaction::CompactionResult.new(atom_id: 'a3', tier: 1, error: 'Failed')
      ]
    end

    let(:batch) { described_class.new(results: results, tier: 1) }

    it 'counts successes' do
      expect(batch.success_count).to eq(2)
    end

    it 'counts errors' do
      expect(batch.error_count).to eq(1)
    end

    it 'serializes to hash' do
      hash = batch.to_h
      expect(hash[:total]).to eq(3)
      expect(hash[:success_count]).to eq(2)
      expect(hash[:error_count]).to eq(1)
    end
  end
end
