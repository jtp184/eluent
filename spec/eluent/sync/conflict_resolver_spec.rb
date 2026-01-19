# frozen_string_literal: true

RSpec.describe Eluent::Sync::ConflictResolver do
  let(:resolver) { described_class.new }

  describe '#resolve_atom_conflict' do
    context 'when both are discarded' do
      let(:base) { build(:atom, :discarded) }
      let(:local) { build(:atom, :discarded, id: base.id) }
      let(:remote) { build(:atom, :discarded, id: base.id) }

      it 'returns :delete' do
        result = resolver.resolve_atom_conflict(base: base, local: local, remote: remote)
        expect(result).to eq(:delete)
      end
    end

    context 'when local is discarded but remote was edited' do
      let(:base) { build(:atom, updated_at: Time.utc(2025, 1, 1)) }
      let(:local) { build(:atom, :discarded, id: base.id) }
      let(:remote) { build(:atom, id: base.id, updated_at: Time.utc(2025, 1, 2)) }

      it 'returns :keep_remote (resurrection rule)' do
        result = resolver.resolve_atom_conflict(base: base, local: local, remote: remote)
        expect(result).to eq(:keep_remote)
      end
    end

    context 'when local is discarded and remote is unchanged' do
      let(:base) { build(:atom, updated_at: Time.utc(2025, 1, 1)) }
      let(:local) { build(:atom, :discarded, id: base.id) }
      let(:remote) { build(:atom, id: base.id, updated_at: Time.utc(2025, 1, 1)) }

      it 'returns :delete' do
        result = resolver.resolve_atom_conflict(base: base, local: local, remote: remote)
        expect(result).to eq(:delete)
      end
    end

    context 'when remote is discarded but local was edited' do
      let(:base) { build(:atom, updated_at: Time.utc(2025, 1, 1)) }
      let(:local) { build(:atom, id: base.id, updated_at: Time.utc(2025, 1, 2)) }
      let(:remote) { build(:atom, :discarded, id: base.id) }

      it 'returns :keep_local (resurrection rule)' do
        result = resolver.resolve_atom_conflict(base: base, local: local, remote: remote)
        expect(result).to eq(:keep_local)
      end
    end

    context 'when neither is discarded' do
      let(:base) { build(:atom) }
      let(:local) { build(:atom, id: base.id) }
      let(:remote) { build(:atom, id: base.id) }

      it 'returns :merge' do
        result = resolver.resolve_atom_conflict(base: base, local: local, remote: remote)
        expect(result).to eq(:merge)
      end
    end

    context 'when base is nil (new on one side)' do
      let(:local) { build(:atom, :discarded) }
      let(:remote) { build(:atom, id: local.id) }

      it 'returns :keep_remote for resurrection with nil base' do
        result = resolver.resolve_atom_conflict(base: nil, local: local, remote: remote)
        expect(result).to eq(:keep_remote)
      end
    end
  end

  describe '#deduplicate_comments' do
    let(:comment1) { build(:comment, content: 'Test', created_at: Time.utc(2025, 1, 1)) }
    let(:comment2) { build(:comment, content: 'Test', created_at: Time.utc(2025, 1, 2)) }
    let(:comment3) do
      build(:comment, parent_id: comment1.parent_id, author: comment1.author,
                      content: comment1.content, created_at: comment1.created_at)
    end

    it 'returns unique comments' do
      result = resolver.deduplicate_comments([comment1, comment2])
      expect(result).to contain_exactly(comment1, comment2)
    end

    it 'keeps earliest when duplicates found by dedup_key' do
      result = resolver.deduplicate_comments([comment1, comment3])
      expect(result.size).to eq(1)
      expect(result.first.created_at).to eq(comment1.created_at)
    end
  end

  describe '#deduplicate_bonds' do
    let(:bond1) { build(:bond, source_id: 'a', target_id: 'b', dependency_type: :blocks) }
    let(:bond2) { build(:bond, source_id: 'a', target_id: 'c', dependency_type: :blocks) }
    let(:bond3) { build(:bond, source_id: 'a', target_id: 'b', dependency_type: :blocks) }

    it 'returns unique bonds by key' do
      result = resolver.deduplicate_bonds([bond1, bond2, bond3])
      expect(result.size).to eq(2)
      expect(result.map(&:key)).to contain_exactly(bond1.key, bond2.key)
    end
  end
end
