# frozen_string_literal: true

RSpec.describe Eluent::Graph::BlockingResolver do
  let(:indexer) { Eluent::Storage::Indexer.new }
  let(:graph) { Eluent::Graph::DependencyGraph.new(indexer) }
  subject(:resolver) { described_class.new(indexer: indexer, dependency_graph: graph) }

  let(:open_atom) { build(:atom, :open) }
  let(:closed_atom) { build(:atom, :closed) }
  let(:dependent_atom) { build(:atom, :open) }

  before do
    [open_atom, closed_atom, dependent_atom].each { |atom| indexer.index_atom(atom) }
  end

  describe 'FAILURE_PATTERN' do
    it 'matches failure reasons' do
      %w[fail failure failed error abort aborted].each do |reason|
        expect(reason).to match(described_class::FAILURE_PATTERN)
      end
    end

    it 'does not match success reasons' do
      %w[completed done success wont_fix duplicate].each do |reason|
        expect(reason).not_to match(described_class::FAILURE_PATTERN)
      end
    end
  end

  describe '#blocked?' do
    context 'with nil atom' do
      it 'returns not blocked' do
        result = resolver.blocked?(nil)
        expect(result).to eq({ blocked: false, blockers: [] })
      end
    end

    context 'with no dependencies' do
      it 'returns not blocked' do
        result = resolver.blocked?(dependent_atom)
        expect(result[:blocked]).to be false
        expect(result[:blockers]).to be_empty
      end
    end

    context 'with blocks dependency type' do
      context 'when source is open' do
        before do
          indexer.index_bond(build(:bond, source_id: open_atom.id, target_id: dependent_atom.id, dependency_type: :blocks))
        end

        it 'returns blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be true
          expect(result[:blockers].first.source_id).to eq(open_atom.id)
        end
      end

      context 'when source is closed' do
        before do
          indexer.index_bond(build(:bond, source_id: closed_atom.id, target_id: dependent_atom.id, dependency_type: :blocks))
        end

        it 'returns not blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be false
        end
      end
    end

    context 'with conditional_blocks dependency type' do
      let(:failed_atom) { build(:atom, :closed, close_reason: 'failed') }
      let(:success_atom) { build(:atom, :closed, close_reason: 'completed') }

      before do
        indexer.index_atom(failed_atom)
        indexer.index_atom(success_atom)
      end

      context 'when source failed' do
        before do
          indexer.index_bond(build(:bond, source_id: failed_atom.id, target_id: dependent_atom.id, dependency_type: :conditional_blocks))
        end

        it 'returns blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be true
        end
      end

      context 'when source succeeded' do
        before do
          indexer.index_bond(build(:bond, source_id: success_atom.id, target_id: dependent_atom.id, dependency_type: :conditional_blocks))
        end

        it 'returns not blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be false
        end
      end

      context 'when source is still open' do
        before do
          indexer.index_bond(build(:bond, source_id: open_atom.id, target_id: dependent_atom.id, dependency_type: :conditional_blocks))
        end

        it 'returns not blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be false
        end
      end
    end

    context 'with waits_for dependency type' do
      context 'when source and all descendants are closed' do
        let(:waits_source) { build(:atom, :closed) }
        let(:waits_descendant) { build(:atom, :closed) }

        before do
          indexer.index_atom(waits_source)
          indexer.index_atom(waits_descendant)
          indexer.index_bond(build(:bond, source_id: waits_source.id, target_id: waits_descendant.id))
          indexer.index_bond(build(:bond, source_id: waits_source.id, target_id: dependent_atom.id, dependency_type: :waits_for))
        end

        it 'returns not blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be false
        end
      end

      context 'when source has open descendants' do
        let(:waits_source) { build(:atom, :closed) }
        let(:waits_open_descendant) { build(:atom, :open) }

        before do
          indexer.index_atom(waits_source)
          indexer.index_atom(waits_open_descendant)
          indexer.index_bond(build(:bond, source_id: waits_source.id, target_id: waits_open_descendant.id))
          indexer.index_bond(build(:bond, source_id: waits_source.id, target_id: dependent_atom.id, dependency_type: :waits_for))
        end

        it 'returns blocked' do
          result = resolver.blocked?(dependent_atom)
          expect(result[:blocked]).to be true
        end
      end
    end

    context 'with parent_child blocking via parent_id' do
      let(:parent_atom) { build(:atom, :open) }
      let(:child_atom) { build(:atom, :open, parent_id: parent_atom.id) }

      before do
        indexer.index_atom(parent_atom)
        indexer.index_atom(child_atom)
      end

      it 'blocks child when parent is not closed' do
        result = resolver.blocked?(child_atom)
        expect(result[:blocked]).to be true
      end

      context 'when parent is closed' do
        let(:parent_atom) { build(:atom, :closed) }

        it 'does not block child' do
          result = resolver.blocked?(child_atom)
          expect(result[:blocked]).to be false
        end
      end

      context 'with nested parent chain (grandparent -> parent -> child)' do
        let(:grandparent_atom) { build(:atom, :open) }
        let(:parent_atom) { build(:atom, :closed, parent_id: grandparent_atom.id) }
        let(:child_atom) { build(:atom, :open, parent_id: parent_atom.id) }

        before do
          indexer.index_atom(grandparent_atom)
          indexer.index_atom(parent_atom)
          indexer.index_atom(child_atom)
        end

        it 'does not block child when parent is closed (even if grandparent is open)' do
          result = resolver.blocked?(child_atom)
          expect(result[:blocked]).to be false
        end
      end
    end

    it 'caches results' do
      resolver.blocked?(dependent_atom)

      # Modify the underlying data
      indexer.index_bond(build(:bond, source_id: open_atom.id, target_id: dependent_atom.id))

      # Should return cached result (not blocked)
      result = resolver.blocked?(dependent_atom)
      expect(result[:blocked]).to be false
    end
  end

  describe '#ready?' do
    context 'with nil atom' do
      it 'returns false' do
        expect(resolver.ready?(nil)).to be false
      end
    end

    context 'with abstract atom' do
      let(:epic_atom) { build(:atom, :epic) }

      before { indexer.index_atom(epic_atom) }

      it 'returns false by default' do
        expect(resolver.ready?(epic_atom)).to be false
      end

      it 'returns true when include_abstract is true' do
        expect(resolver.ready?(epic_atom, include_abstract: true)).to be true
      end
    end

    context 'with closed atom' do
      it 'returns false' do
        expect(resolver.ready?(closed_atom)).to be false
      end
    end

    context 'with discarded atom' do
      let(:discarded_atom) { build(:atom, :discarded) }

      before { indexer.index_atom(discarded_atom) }

      it 'returns false' do
        expect(resolver.ready?(discarded_atom)).to be false
      end
    end

    context 'with deferred atom' do
      let(:deferred_future) { build(:atom, :defer_future) }
      let(:deferred_past) { build(:atom, :defer_past) }

      before do
        indexer.index_atom(deferred_future)
        indexer.index_atom(deferred_past)
      end

      it 'returns false when deferred to future' do
        expect(resolver.ready?(deferred_future)).to be false
      end

      it 'returns true when defer_until has passed' do
        expect(resolver.ready?(deferred_past)).to be true
      end
    end

    context 'with blocked atom' do
      before do
        indexer.index_bond(build(:bond, source_id: open_atom.id, target_id: dependent_atom.id))
      end

      it 'returns false' do
        expect(resolver.ready?(dependent_atom)).to be false
      end
    end

    context 'with ready atom' do
      it 'returns true' do
        expect(resolver.ready?(open_atom)).to be true
      end
    end
  end

  describe '#clear_cache' do
    it 'clears the internal cache' do
      resolver.blocked?(dependent_atom)
      indexer.index_bond(build(:bond, source_id: open_atom.id, target_id: dependent_atom.id))

      resolver.clear_cache

      result = resolver.blocked?(dependent_atom)
      expect(result[:blocked]).to be true
    end
  end
end
