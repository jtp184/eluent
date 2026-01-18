# frozen_string_literal: true

RSpec.describe Eluent::Models::Bond do
  let(:source_id) { test_atom_id('SOURCEIDABCDEFGH') }
  let(:target_id) { test_atom_id('TARGETIDABCDEFGH') }

  let(:bond) { build(:bond, source_id: source_id, target_id: target_id, dependency_type: :blocks) }
  let(:same_identity_entity) { build(:bond, source_id: source_id, target_id: target_id, dependency_type: :blocks) }
  let(:different_identity_entity) do
    build(:bond, source_id: source_id, target_id: target_id, dependency_type: :related)
  end
  let(:entity) { bond }
  let(:expected_type) { 'bond' }
  let(:expected_keys) { %i[_type source_id target_id dependency_type created_at metadata] }
  let(:timestamp_keys) { %i[created_at] }

  it_behaves_like 'an entity with identity'
  it_behaves_like 'a serializable entity'

  describe '#initialize' do
    it 'requires source_id and target_id' do
      bond = described_class.new(source_id: 'src', target_id: 'tgt')
      expect(bond.source_id).to eq('src')
      expect(bond.target_id).to eq('tgt')
    end

    it 'defaults to blocks dependency type' do
      bond = described_class.new(source_id: 'src', target_id: 'tgt')
      expect(bond.dependency_type).to eq(Eluent::Models::DependencyType[:blocks])
    end

    it 'validates dependency_type' do
      expect { described_class.new(source_id: 'src', target_id: 'tgt', dependency_type: :invalid) }
        .to raise_error(Eluent::Models::ValidationError)
    end

    it 'raises SelfReferenceError for self-referential bonds' do
      expect { described_class.new(source_id: 'same', target_id: 'same') }
        .to raise_error(Eluent::Models::SelfReferenceError)
    end

    it 'accepts metadata' do
      bond = described_class.new(source_id: 'src', target_id: 'tgt', metadata: { key: 'value' })
      expect(bond.metadata).to eq({ key: 'value' })
    end
  end

  describe 'dependency type predicate methods' do
    Eluent::Models::DependencyType.all.each_key do |dep_name|
      describe "##{dep_name}?" do
        it "returns true when dependency_type is #{dep_name}" do
          bond = build(:bond, dependency_type: dep_name)
          expect(bond.public_send("#{dep_name}?")).to be true
        end

        it "returns false when dependency_type is not #{dep_name}" do
          other_type = (Eluent::Models::DependencyType.all.keys - [dep_name]).first
          bond = build(:bond, dependency_type: other_type)
          expect(bond.public_send("#{dep_name}?")).to be false
        end
      end
    end
  end

  describe '#blocking?' do
    it 'delegates to dependency_type' do
      blocking_bond = build(:bond, :blocks)
      non_blocking_bond = build(:bond, :related)

      expect(blocking_bond).to be_blocking
      expect(non_blocking_bond).not_to be_blocking
    end
  end

  describe '#to_h' do
    subject(:hash) { bond.to_h }

    it 'includes the bond type marker' do
      expect(hash[:_type]).to eq('bond')
    end

    it 'converts dependency_type to string' do
      expect(hash[:dependency_type]).to eq(bond.dependency_type.to_s)
    end

    it 'includes source_id and target_id' do
      expect(hash[:source_id]).to eq(source_id)
      expect(hash[:target_id]).to eq(target_id)
    end
  end

  describe '#key' do
    it 'returns a unique key for deduplication' do
      bond = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)
      expect(bond.key).to eq('src.tgt.blocks')
    end

    it 'produces different keys for different dependency types' do
      bond1 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)
      bond2 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :related)

      expect(bond1.key).not_to eq(bond2.key)
    end
  end

  describe '#==' do
    it 'considers bonds equal when source, target, and type match' do
      bond1 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)
      bond2 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)

      expect(bond1).to eq(bond2)
    end

    it 'considers bonds unequal with different source_id' do
      bond1 = build(:bond, source_id: 'src1', target_id: 'tgt', dependency_type: :blocks)
      bond2 = build(:bond, source_id: 'src2', target_id: 'tgt', dependency_type: :blocks)

      expect(bond1).not_to eq(bond2)
    end

    it 'considers bonds unequal with different target_id' do
      bond1 = build(:bond, source_id: 'src', target_id: 'tgt1', dependency_type: :blocks)
      bond2 = build(:bond, source_id: 'src', target_id: 'tgt2', dependency_type: :blocks)

      expect(bond1).not_to eq(bond2)
    end

    it 'considers bonds unequal with different dependency_type' do
      bond1 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)
      bond2 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :related)

      expect(bond1).not_to eq(bond2)
    end
  end

  describe '#hash' do
    it 'produces the same hash for equal bonds' do
      bond1 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)
      bond2 = build(:bond, source_id: 'src', target_id: 'tgt', dependency_type: :blocks)

      expect(bond1.hash).to eq(bond2.hash)
    end
  end

  describe 'factory traits' do
    it 'creates blocking bonds' do
      bond = build(:bond, :blocking)
      expect(bond).to be_blocking
    end

    it 'creates non-blocking bonds' do
      bond = build(:bond, :non_blocking)
      expect(bond).not_to be_blocking
    end

    it 'creates bonds with metadata' do
      bond = build(:bond, :with_metadata)
      expect(bond.metadata).not_to be_empty
    end
  end
end
