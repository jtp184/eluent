# frozen_string_literal: true

RSpec.describe Eluent::Storage::Serializers::AtomSerializer do
  let(:serializer) { described_class }
  let(:entity) { build(:atom) }
  let(:expected_type) { 'atom' }
  let(:identity_attributes) { %i[id title status issue_type priority] }

  it_behaves_like 'a serializer'

  describe '.deserialize' do
    let(:atom_hash) do
      {
        _type: 'atom',
        id: 'test-01ABCDEFGH1234567890',
        title: 'Test Atom',
        description: 'A test description',
        status: 'open',
        issue_type: 'task',
        priority: 2,
        labels: %w[urgent backend],
        assignee: 'user1',
        parent_id: nil,
        defer_until: nil,
        close_reason: nil,
        created_at: '2025-06-15T12:00:00Z',
        updated_at: '2025-06-15T12:00:00Z',
        metadata: { source: 'test' }
      }
    end

    it 'returns nil for non-atom data' do
      expect(serializer.deserialize({ _type: 'bond' })).to be_nil
    end

    it 'reconstructs an Atom from hash data' do
      atom = serializer.deserialize(atom_hash)
      expect(atom).to be_a(Eluent::Models::Atom)
    end

    it 'preserves all attributes' do
      atom = serializer.deserialize(atom_hash)

      expect(atom.id).to eq('test-01ABCDEFGH1234567890')
      expect(atom.title).to eq('Test Atom')
      expect(atom.description).to eq('A test description')
      expect(atom.priority).to eq(2)
    end

    it 'converts status to Status object' do
      atom = serializer.deserialize(atom_hash)
      expect(atom.status).to eq(Eluent::Models::Status[:open])
    end

    it 'converts issue_type to IssueType object' do
      atom = serializer.deserialize(atom_hash)
      expect(atom.issue_type).to eq(Eluent::Models::IssueType[:task])
    end

    it 'parses timestamp strings' do
      atom = serializer.deserialize(atom_hash)
      expect(atom.created_at).to eq(Time.utc(2025, 6, 15, 12, 0, 0))
    end

    it 'handles string keys' do
      string_hash = atom_hash.transform_keys(&:to_s)
      atom = serializer.deserialize(string_hash)
      expect(atom.id).to eq('test-01ABCDEFGH1234567890')
    end
  end

  describe '.atom?' do
    it 'is aliased to type_match?' do
      expect(serializer.atom?({ _type: 'atom' })).to be true
      expect(serializer.atom?({ _type: 'bond' })).to be false
    end
  end

  describe 'round-trip serialization' do
    it 'preserves atom data through serialize/deserialize' do
      original = build(:atom, :with_labels, :with_assignee, priority: 1)
      json = serializer.serialize(original)
      parsed = JSON.parse(json, symbolize_names: true)
      restored = serializer.deserialize(parsed)

      expect(restored.id).to eq(original.id)
      expect(restored.title).to eq(original.title)
      expect(restored.status).to eq(original.status)
      expect(restored.issue_type).to eq(original.issue_type)
      expect(restored.priority).to eq(original.priority)
      expect(restored.labels).to eq(original.labels)
      expect(restored.assignee).to eq(original.assignee)
    end

    it 'preserves defer_until through serialization' do
      original = build(:atom, :deferred)
      json = serializer.serialize(original)
      parsed = JSON.parse(json, symbolize_names: true)
      restored = serializer.deserialize(parsed)

      expect(restored.defer_until).to be_within(1).of(original.defer_until)
    end
  end
end
