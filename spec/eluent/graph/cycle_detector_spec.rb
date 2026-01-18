# frozen_string_literal: true

RSpec.describe Eluent::Graph::CycleDetector do
  let(:indexer) { Eluent::Storage::Indexer.new }
  let(:graph) { Eluent::Graph::DependencyGraph.new(indexer) }
  subject(:detector) { described_class.new(graph) }

  let(:atom_a) { build(:atom) }
  let(:atom_b) { build(:atom) }
  let(:atom_c) { build(:atom) }

  before do
    [atom_a, atom_b, atom_c].each { |atom| indexer.index_atom(atom) }
  end

  describe Eluent::Graph::CycleDetectedError do
    it 'stores the cycle path' do
      error = described_class.new(%w[a b c a])
      expect(error.cycle_path).to eq(%w[a b c a])
    end

    it 'formats the message with path' do
      error = described_class.new(%w[a b c a])
      expect(error.message).to eq('Cycle detected: a -> b -> c -> a')
    end
  end

  describe '#validate_bond' do
    context 'with no existing bonds' do
      it 'returns valid for any new bond' do
        result = detector.validate_bond(
          source_id: atom_a.id,
          target_id: atom_b.id,
          dependency_type: :blocks
        )
        expect(result).to eq({ valid: true })
      end
    end

    context 'with existing linear chain' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_c.id))
      end

      it 'returns valid for extending the chain' do
        new_atom = build(:atom)
        indexer.index_atom(new_atom)

        result = detector.validate_bond(
          source_id: atom_c.id,
          target_id: new_atom.id,
          dependency_type: :blocks
        )
        expect(result).to eq({ valid: true })
      end

      it 'returns invalid when adding would create a cycle' do
        result = detector.validate_bond(
          source_id: atom_c.id,
          target_id: atom_a.id,
          dependency_type: :blocks
        )

        expect(result[:valid]).to be false
        expect(result[:cycle_path]).to include(atom_c.id, atom_a.id)
      end

      it 'returns invalid for direct back-edge' do
        result = detector.validate_bond(
          source_id: atom_b.id,
          target_id: atom_a.id,
          dependency_type: :blocks
        )

        expect(result[:valid]).to be false
      end
    end

    context 'with non-blocking dependency type' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_c.id))
      end

      it 'returns valid even when cycle would exist for blocking' do
        result = detector.validate_bond(
          source_id: atom_c.id,
          target_id: atom_a.id,
          dependency_type: :related
        )
        expect(result).to eq({ valid: true })
      end
    end

    context 'with self-reference' do
      it 'returns valid (self-reference is handled elsewhere)' do
        result = detector.validate_bond(
          source_id: atom_a.id,
          target_id: atom_a.id,
          dependency_type: :blocks
        )
        expect(result).to eq({ valid: true })
      end
    end
  end

  describe '#validate_bond!' do
    context 'when bond is valid' do
      it 'returns valid result' do
        result = detector.validate_bond!(
          source_id: atom_a.id,
          target_id: atom_b.id,
          dependency_type: :blocks
        )
        expect(result).to eq({ valid: true })
      end
    end

    context 'when bond would create a cycle' do
      before do
        indexer.index_bond(build(:bond, source_id: atom_a.id, target_id: atom_b.id))
        indexer.index_bond(build(:bond, source_id: atom_b.id, target_id: atom_c.id))
      end

      it 'raises CycleDetectedError' do
        expect do
          detector.validate_bond!(
            source_id: atom_c.id,
            target_id: atom_a.id,
            dependency_type: :blocks
          )
        end.to raise_error(Eluent::Graph::CycleDetectedError)
      end

      it 'includes cycle path in error' do
        expect do
          detector.validate_bond!(
            source_id: atom_c.id,
            target_id: atom_a.id,
            dependency_type: :blocks
          )
        end.to raise_error do |error|
          expect(error.cycle_path).not_to be_empty
        end
      end
    end
  end
end
