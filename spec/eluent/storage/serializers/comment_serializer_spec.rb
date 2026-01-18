# frozen_string_literal: true

RSpec.describe Eluent::Storage::Serializers::CommentSerializer do
  let(:serializer) { described_class }
  let(:entity) { build(:comment) }
  let(:expected_type) { 'comment' }
  let(:identity_attributes) { %i[id parent_id author content] }

  it_behaves_like 'a serializer'

  describe '.deserialize' do
    let(:comment_hash) do
      {
        _type: 'comment',
        id: 'test-01ABCDEFGH1234567890-c1',
        parent_id: 'test-01ABCDEFGH1234567890',
        author: 'claude-bot',
        content: 'This is a test comment with analysis.',
        created_at: '2025-06-15T12:00:00Z',
        updated_at: '2025-06-15T12:30:00Z'
      }
    end

    it 'returns nil for non-comment data' do
      expect(serializer.deserialize({ _type: 'atom' })).to be_nil
    end

    it 'reconstructs a Comment from hash data' do
      comment = serializer.deserialize(comment_hash)
      expect(comment).to be_a(Eluent::Models::Comment)
    end

    it 'preserves all attributes' do
      comment = serializer.deserialize(comment_hash)

      expect(comment.id).to eq('test-01ABCDEFGH1234567890-c1')
      expect(comment.parent_id).to eq('test-01ABCDEFGH1234567890')
      expect(comment.author).to eq('claude-bot')
      expect(comment.content).to eq('This is a test comment with analysis.')
    end

    it 'parses timestamp strings' do
      comment = serializer.deserialize(comment_hash)
      expect(comment.created_at).to eq(Time.utc(2025, 6, 15, 12, 0, 0))
      expect(comment.updated_at).to eq(Time.utc(2025, 6, 15, 12, 30, 0))
    end

    it 'handles string keys' do
      string_hash = comment_hash.transform_keys(&:to_s)
      comment = serializer.deserialize(string_hash)
      expect(comment.id).to eq('test-01ABCDEFGH1234567890-c1')
    end
  end

  describe '.comment?' do
    it 'is aliased to type_match?' do
      expect(serializer.comment?({ _type: 'comment' })).to be true
      expect(serializer.comment?({ _type: 'atom' })).to be false
    end
  end

  describe 'round-trip serialization' do
    it 'preserves comment data through serialize/deserialize' do
      original = build(:comment, :with_code)
      json = serializer.serialize(original)
      parsed = JSON.parse(json, symbolize_names: true)
      restored = serializer.deserialize(parsed)

      expect(restored.id).to eq(original.id)
      expect(restored.parent_id).to eq(original.parent_id)
      expect(restored.author).to eq(original.author)
      expect(restored.content).to eq(original.content)
    end

    it 'preserves timestamps through serialization' do
      original = build(:comment)
      json = serializer.serialize(original)
      parsed = JSON.parse(json, symbolize_names: true)
      restored = serializer.deserialize(parsed)

      expect(restored.created_at).to be_within(1).of(original.created_at)
      expect(restored.updated_at).to be_within(1).of(original.updated_at)
    end
  end
end
