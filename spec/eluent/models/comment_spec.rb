# frozen_string_literal: true

RSpec.describe Eluent::Models::Comment do
  let(:comment_id) { test_comment_id }
  let(:parent_id) { test_atom_id }

  let(:comment) { build(:comment, id: comment_id, parent_id: parent_id) }
  let(:same_identity_entity) { build(:comment, id: comment_id, parent_id: 'other-parent') }
  let(:different_identity_entity) { build(:comment, id: "#{comment_id}-different", parent_id: parent_id) }
  let(:entity) { comment }
  let(:expected_type) { 'comment' }
  let(:expected_keys) { %i[_type id parent_id author content created_at updated_at] }
  let(:timestamp_keys) { %i[created_at updated_at] }

  it_behaves_like 'an entity with identity'
  it_behaves_like 'a serializable entity'

  describe '#initialize' do
    it 'requires id, parent_id, author, and content' do
      comment = described_class.new(
        id: 'comment-1',
        parent_id: 'atom-1',
        author: 'user',
        content: 'Test content'
      )

      expect(comment.id).to eq('comment-1')
      expect(comment.parent_id).to eq('atom-1')
      expect(comment.author).to eq('user')
      expect(comment.content).to eq('Test content')
    end

    it 'sets default timestamps' do
      Timecop.freeze do
        comment = described_class.new(
          id: 'c1',
          parent_id: 'a1',
          author: 'user',
          content: 'Test'
        )

        expect(comment.created_at).to be_within(1).of(Time.now.utc)
        expect(comment.updated_at).to be_within(1).of(Time.now.utc)
      end
    end

    it 'validates content length' do
      long_content = 'A' * 65_537
      expect do
        described_class.new(
          id: 'c1',
          parent_id: 'a1',
          author: 'user',
          content: long_content
        )
      end.to raise_error(Eluent::Models::ValidationError)
    end

    it 'parses time strings' do
      comment = described_class.new(
        id: 'c1',
        parent_id: 'a1',
        author: 'user',
        content: 'Test',
        created_at: '2025-06-15T12:00:00Z'
      )

      expect(comment.created_at).to eq(Time.utc(2025, 6, 15, 12, 0, 0))
    end
  end

  describe '#to_h' do
    subject(:hash) { comment.to_h }

    it 'includes the comment type marker' do
      expect(hash[:_type]).to eq('comment')
    end

    it 'includes all fields' do
      expect(hash[:id]).to eq(comment.id)
      expect(hash[:parent_id]).to eq(comment.parent_id)
      expect(hash[:author]).to eq(comment.author)
      expect(hash[:content]).to eq(comment.content)
    end

    it 'formats timestamps as ISO8601' do
      expect(hash[:created_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(hash[:updated_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe '#dedup_key' do
    it 'returns a 16-character hex string' do
      key = comment.dedup_key
      expect(key).to match(/\A[0-9a-f]{16}\z/)
    end

    it 'produces the same key for identical content' do
      Timecop.freeze do
        comment1 = build(:comment, id: 'c1', parent_id: 'p1', author: 'user', content: 'Same')
        comment2 = build(:comment, id: 'c2', parent_id: 'p1', author: 'user', content: 'Same')

        expect(comment1.dedup_key).to eq(comment2.dedup_key)
      end
    end

    it 'produces different keys for different content' do
      comment1 = build(:comment, content: 'Content A')
      comment2 = build(:comment, content: 'Content B')

      expect(comment1.dedup_key).not_to eq(comment2.dedup_key)
    end

    it 'produces different keys for different authors' do
      Timecop.freeze do
        comment1 = build(:comment, parent_id: 'p1', author: 'user1', content: 'Same')
        comment2 = build(:comment, parent_id: 'p1', author: 'user2', content: 'Same')

        expect(comment1.dedup_key).not_to eq(comment2.dedup_key)
      end
    end

    it 'produces different keys for different parent_ids' do
      Timecop.freeze do
        comment1 = build(:comment, parent_id: 'parent1', author: 'user', content: 'Same')
        comment2 = build(:comment, parent_id: 'parent2', author: 'user', content: 'Same')

        expect(comment1.dedup_key).not_to eq(comment2.dedup_key)
      end
    end
  end

  describe '#==' do
    it 'considers comments equal by id only' do
      comment1 = build(:comment, id: 'same-id', content: 'Content A')
      comment2 = build(:comment, id: 'same-id', content: 'Content B')

      expect(comment1).to eq(comment2)
    end

    it 'considers comments unequal with different ids' do
      comment1 = build(:comment, id: 'id-1', content: 'Same')
      comment2 = build(:comment, id: 'id-2', content: 'Same')

      expect(comment1).not_to eq(comment2)
    end
  end

  describe '#hash' do
    it 'produces the same hash for comments with the same id' do
      comment1 = build(:comment, id: 'same-id')
      comment2 = build(:comment, id: 'same-id')

      expect(comment1.hash).to eq(comment2.hash)
    end
  end

  describe 'factory traits' do
    it 'creates comments by bot' do
      comment = build(:comment, :by_bot)
      expect(comment.author).to eq('claude-bot')
    end

    it 'creates short comments' do
      comment = build(:comment, :short)
      expect(comment.content.length).to be < 100
    end

    it 'creates long comments' do
      comment = build(:comment, :long)
      expect(comment.content.length).to be > 100
    end

    it 'creates comments with code' do
      comment = build(:comment, :with_code)
      expect(comment.content).to include('```')
    end

    it 'creates old comments' do
      comment = build(:comment, :old)
      expect(comment.created_at).to be < Time.now.utc - 86_400
    end
  end
end
