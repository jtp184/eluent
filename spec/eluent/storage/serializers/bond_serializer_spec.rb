# frozen_string_literal: true

RSpec.describe Eluent::Storage::Serializers::BondSerializer do
  let(:serializer) { described_class }
  let(:entity) { build(:bond) }
  let(:expected_type) { 'bond' }
  let(:identity_attributes) { %i[source_id target_id dependency_type] }

  it_behaves_like 'a serializer'

  describe '.deserialize' do
    let(:bond_hash) do
      {
        _type: 'bond',
        source_id: 'test-01ABCDEFGH1234567890',
        target_id: 'test-01ZYXWVUTSRQ987654321',
        dependency_type: 'blocks',
        created_at: '2025-06-15T12:00:00Z',
        metadata: { reason: 'technical' }
      }
    end

    it 'returns nil for non-bond data' do
      expect(serializer.deserialize({ _type: 'atom' })).to be_nil
    end

    it 'reconstructs a Bond from hash data' do
      bond = serializer.deserialize(bond_hash)
      expect(bond).to be_a(Eluent::Models::Bond)
    end

    it 'preserves all attributes' do
      bond = serializer.deserialize(bond_hash)

      expect(bond.source_id).to eq('test-01ABCDEFGH1234567890')
      expect(bond.target_id).to eq('test-01ZYXWVUTSRQ987654321')
    end

    it 'converts dependency_type to DependencyType object' do
      bond = serializer.deserialize(bond_hash)
      expect(bond.dependency_type).to eq(Eluent::Models::DependencyType[:blocks])
    end

    it 'parses timestamp strings' do
      bond = serializer.deserialize(bond_hash)
      expect(bond.created_at).to eq(Time.utc(2025, 6, 15, 12, 0, 0))
    end

    it 'preserves metadata' do
      bond = serializer.deserialize(bond_hash)
      expect(bond.metadata).to eq({ reason: 'technical' })
    end

    it 'handles string keys' do
      string_hash = bond_hash.transform_keys(&:to_s)
      bond = serializer.deserialize(string_hash)
      expect(bond.source_id).to eq('test-01ABCDEFGH1234567890')
    end
  end

  describe '.bond?' do
    it 'is aliased to type_match?' do
      expect(serializer.bond?({ _type: 'bond' })).to be true
      expect(serializer.bond?({ _type: 'atom' })).to be false
    end
  end

  describe 'round-trip serialization' do
    Eluent::Models::DependencyType.all.each_key do |dep_type|
      it "preserves #{dep_type} dependency type" do
        original = build(:bond, dependency_type: dep_type)
        json = serializer.serialize(original)
        parsed = JSON.parse(json, symbolize_names: true)
        restored = serializer.deserialize(parsed)

        expect(restored.dependency_type).to eq(original.dependency_type)
      end
    end

    it 'preserves metadata through serialization' do
      original = build(:bond, :with_metadata)
      json = serializer.serialize(original)
      parsed = JSON.parse(json, symbolize_names: true)
      restored = serializer.deserialize(parsed)

      expect(restored.metadata).to eq(original.metadata)
    end
  end
end
