# frozen_string_literal: true

RSpec.describe Eluent::Compaction::Summarizer do
  let(:root_path) { Dir.mktmpdir }
  let(:summarizer) { described_class.new(repository: repository) }
  let(:repository) do
    repo = Eluent::Storage::JsonlRepository.new(root_path)
    repo.init(repo_name: 'testrepo')
    repo
  end

  after { FileUtils.rm_rf(root_path) }

  describe '#summarize_description' do
    let(:atom) do
      repository.create_atom(
        title: 'Test Item',
        description: 'A' * 1000
      )
    end

    context 'tier 1' do
      it 'truncates description to 500 characters' do
        summary = summarizer.summarize_description(atom, tier: 1)
        expect(summary.length).to be <= 503 # 500 + "..."
      end

      it 'preserves short descriptions' do
        short_atom = repository.create_atom(title: 'Short', description: 'Brief description.')
        summary = summarizer.summarize_description(short_atom, tier: 1)
        expect(summary).to eq('Brief description.')
      end

      it 'returns nil for nil description' do
        nil_atom = repository.create_atom(title: 'No desc', description: nil)
        summary = summarizer.summarize_description(nil_atom, tier: 1)
        expect(summary).to be_nil
      end
    end

    context 'tier 2' do
      it 'extracts first sentence or line' do
        multi_line = repository.create_atom(
          title: 'Multi',
          description: "First line.\nSecond line.\nThird line."
        )
        summary = summarizer.summarize_description(multi_line, tier: 2)
        expect(summary).to match(/First line/)
      end

      it 'truncates to 100 characters max' do
        long_first = repository.create_atom(
          title: 'Long',
          description: 'A' * 200
        )
        summary = summarizer.summarize_description(long_first, tier: 2)
        expect(summary.length).to be <= 103
      end
    end

    it 'raises error for unknown tier' do
      expect { summarizer.summarize_description(atom, tier: 99) }
        .to raise_error(Eluent::Compaction::CompactionError, /Unknown compaction tier/)
    end
  end

  describe '#summarize_comments' do
    let(:atom) { repository.create_atom(title: 'With Comments') }

    context 'with no comments' do
      it 'returns nil' do
        summary = summarizer.summarize_comments(atom)
        expect(summary).to be_nil
      end
    end

    context 'with comments' do
      before do
        repository.create_comment(parent_id: atom.id, author: 'alice', content: 'First comment')
        repository.create_comment(parent_id: atom.id, author: 'bob', content: 'Second comment')
        repository.create_comment(parent_id: atom.id, author: 'alice', content: 'Final thoughts')
      end

      it 'returns a summary string' do
        summary = summarizer.summarize_comments(atom)
        expect(summary).to be_a(String)
      end

      it 'includes comment count' do
        summary = summarizer.summarize_comments(atom)
        expect(summary).to include('3 comment(s)')
      end

      it 'includes author count' do
        summary = summarizer.summarize_comments(atom)
        expect(summary).to include('2 author(s)')
      end

      it 'includes highlights from comments' do
        summary = summarizer.summarize_comments(atom)
        expect(summary).to include('Discussion highlights')
      end
    end

    context 'with nil author' do
      before do
        comment = repository.create_comment(parent_id: atom.id, author: nil, content: 'Anonymous comment')
        # Force nil author since create_comment might set a default
        comment.author = nil
      end

      it 'uses unknown for nil author in highlights' do
        summary = summarizer.summarize_comments(atom)
        expect(summary).to include('unknown:')
      end
    end

    context 'with two comments having same timestamp' do
      let(:same_time) { Time.now.utc }

      before do
        c1 = repository.create_comment(parent_id: atom.id, author: 'alice', content: 'First')
        c2 = repository.create_comment(parent_id: atom.id, author: 'bob', content: 'Second')
        # Force same timestamp
        c1.created_at = same_time
        c2.created_at = same_time
      end

      it 'does not duplicate highlights for same-timestamp comments' do
        summary = summarizer.summarize_comments(atom)
        # Count the number of highlight lines (lines starting with "- ")
        highlight_lines = summary.lines.select { |l| l.strip.start_with?('- ') }
        expect(highlight_lines.size).to eq(1)
      end
    end
  end

  describe '#generate_compaction_summary' do
    let(:atom) do
      repository.create_atom(
        title: 'Test',
        description: 'Full description here'
      )
    end

    before do
      repository.create_comment(parent_id: atom.id, author: 'alice', content: 'Comment')
    end

    it 'returns hash with all summary components' do
      summary = summarizer.generate_compaction_summary(atom, tier: 1)

      expect(summary).to include(
        :description,
        :comments,
        :compaction_tier,
        :compacted_at,
        :original_description_length,
        :original_comment_count
      )
    end

    it 'includes comment summary for tier 1' do
      summary = summarizer.generate_compaction_summary(atom, tier: 1)
      expect(summary[:comments]).not_to be_nil
    end

    it 'excludes comment summary for tier 2' do
      summary = summarizer.generate_compaction_summary(atom, tier: 2)
      expect(summary[:comments]).to be_nil
    end

    it 'records original lengths' do
      summary = summarizer.generate_compaction_summary(atom, tier: 1)
      expect(summary[:original_description_length]).to eq(21)
      expect(summary[:original_comment_count]).to eq(1)
    end
  end
end
