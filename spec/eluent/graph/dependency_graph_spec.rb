# frozen_string_literal: true

RSpec.describe Eluent::Graph::DependencyGraph do
  let(:indexer) { Eluent::Storage::Indexer.new }
  subject(:graph) { described_class.new(indexer) }

  let(:atom_a) { build(:atom) }
  let(:atom_b) { build(:atom) }
  let(:atom_c) { build(:atom) }
  let(:atom_d) { build(:atom) }

  before do
    [atom_a, atom_b, atom_c, atom_d].each { |atom| indexer.index_atom(atom) }
  end

  describe '#path_exists?' do
    context 'with no bonds' do
      it 'returns false' do
        expect(graph.path_exists?(atom_a.id, atom_b.id)).to be false
      end
    end

    context 'with direct bond' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
      end

      it 'returns true for direct connection' do
        expect(graph.path_exists?(atom_a.id, atom_b.id)).to be true
      end

      it 'returns false for reverse direction' do
        expect(graph.path_exists?(atom_b.id, atom_a.id)).to be false
      end
    end

    context 'with transitive bonds' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_c.id))
      end

      it 'returns true for transitive connection' do
        expect(graph.path_exists?(atom_a.id, atom_c.id)).to be true
      end

      it 'returns false for non-transitive paths' do
        expect(graph.path_exists?(atom_a.id, atom_d.id)).to be false
      end
    end

    context 'with non-blocking bonds' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id, dependency_type: :related))
      end

      it 'returns false when blocking_only is true' do
        expect(graph.path_exists?(atom_a.id, atom_b.id, blocking_only: true)).to be false
      end

      it 'returns true when blocking_only is false' do
        expect(graph.path_exists?(atom_a.id, atom_b.id, blocking_only: false)).to be true
      end
    end

    context 'with nil IDs' do
      it 'returns false for nil source' do
        expect(graph.path_exists?(nil, atom_b.id)).to be false
      end

      it 'returns false for nil target' do
        expect(graph.path_exists?(atom_a.id, nil)).to be false
      end
    end
  end

  describe '#all_descendants' do
    context 'with no bonds' do
      it 'returns empty set' do
        expect(graph.all_descendants(atom_a.id)).to be_empty
      end
    end

    context 'with chain of dependencies' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_c.id))
        indexer.index_bond(build(:bond, source_id: atom_c.id, target_id: atom_d.id))
      end

      it 'returns all transitive descendants' do
        descendants = graph.all_descendants(atom_a.id)
        expect(descendants).to contain_exactly(atom_b.id, atom_c.id, atom_d.id)
      end

      it 'returns partial descendants from middle' do
        descendants = graph.all_descendants(atom_b.id)
        expect(descendants).to contain_exactly(atom_c.id, atom_d.id)
      end
    end

    context 'with branching dependencies' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_c.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_d.id))
      end

      it 'returns all descendants from branches' do
        descendants = graph.all_descendants(atom_a.id)
        expect(descendants).to contain_exactly(atom_b.id, atom_c.id, atom_d.id)
      end
    end

    context 'with nil ID' do
      it 'returns empty set' do
        expect(graph.all_descendants(nil)).to be_empty
      end
    end
  end

  describe '#all_ancestors' do
    context 'with no bonds' do
      it 'returns empty set' do
        expect(graph.all_ancestors(atom_a.id)).to be_empty
      end
    end

    context 'with chain of dependencies' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_c.id))
        indexer.index_bond(build(:bond, source_id: atom_c.id, target_id: atom_d.id))
      end

      it 'returns all transitive ancestors' do
        ancestors = graph.all_ancestors(atom_d.id)
        expect(ancestors).to contain_exactly(atom_a.id, atom_b.id, atom_c.id)
      end

      it 'returns partial ancestors from middle' do
        ancestors = graph.all_ancestors(atom_c.id)
        expect(ancestors).to contain_exactly(atom_a.id, atom_b.id)
      end
    end

    context 'with nil ID' do
      it 'returns empty set' do
        expect(graph.all_ancestors(nil)).to be_empty
      end
    end
  end

  describe '#direct_blockers' do
    before do
      indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
      indexer.index_bond(build(:bond, source_id: atom_c.id, target_id: atom_b.id))
      indexer.index_bond(build(:bond, source_id: atom_d.id, target_id: atom_b.id, dependency_type: :related))
    end

    it 'returns only blocking incoming bonds' do
      blockers = graph.direct_blockers(atom_b.id)
      expect(blockers.map(&:source_id)).to contain_exactly(atom_a.id, atom_c.id)
    end
  end

  describe '#direct_dependents' do
    before do
      indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
      indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_c.id))
      indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_d.id, dependency_type: :related))
    end

    it 'returns only blocking outgoing bonds' do
      dependents = graph.direct_dependents(atom_a.id)
      expect(dependents.map(&:target_id)).to contain_exactly(atom_b.id, atom_c.id)
    end
  end
end
