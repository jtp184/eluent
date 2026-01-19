# frozen_string_literal: true

module Eluent
  module Compaction
    # Raised when compaction fails due to invalid tier or other issues
    class CompactionError < Error; end

    # Generates summaries for compaction of old closed items
    class Summarizer
      MAX_SUMMARY_LENGTH = 500
      MAX_ONELINER_LENGTH = 100

      def initialize(repository:)
        @repository = repository
      end

      def summarize_description(atom, tier:)
        case tier
        when 1 then summarize_tier1_description(atom)
        when 2 then summarize_tier2_description(atom)
        else raise CompactionError, "Unknown compaction tier: #{tier}"
        end
      end

      def summarize_comments(atom)
        comments = repository.comments_for(atom.id)
        return nil if comments.empty?

        comment_count = comments.size
        authors = comments.map(&:author).compact.uniq
        date_range = format_date_range(comments)

        summary_lines = ["Compacted #{comment_count} comment(s) from #{authors.size} author(s)"]
        summary_lines << "Period: #{date_range}" if date_range
        summary_lines << ''
        summary_lines << 'Discussion highlights:'

        # Extract key points from comments
        highlights = extract_highlights(comments)
        highlights.each { |h| summary_lines << "- #{h}" }

        summary_lines.join("\n")
      end

      def generate_compaction_summary(atom, tier:)
        {
          description: summarize_description(atom, tier: tier),
          comments: tier == 1 ? summarize_comments(atom) : nil,
          compaction_tier: tier,
          compacted_at: Time.now.utc.iso8601,
          original_description_length: atom.description&.length || 0,
          original_comment_count: repository.comments_for(atom.id).size
        }
      end

      private

      attr_reader :repository

      def summarize_tier1_description(atom)
        return nil unless atom.description

        desc = atom.description
        return desc if desc.length <= MAX_SUMMARY_LENGTH

        # Try to cut at sentence boundary
        truncated = desc[0, MAX_SUMMARY_LENGTH]
        last_period = truncated.rindex(/[.!?]\s/)

        if last_period && last_period > MAX_SUMMARY_LENGTH / 2
          truncated[0..last_period]
        else
          "#{truncated.strip}..."
        end
      end

      def summarize_tier2_description(atom)
        return nil unless atom.description

        desc = atom.description
        return desc if desc.length <= MAX_ONELINER_LENGTH

        # Extract first line or sentence
        first_line = desc.split("\n").first || desc
        first_sentence = first_line.split(/[.!?]\s/).first || first_line

        if first_sentence.length <= MAX_ONELINER_LENGTH
          first_sentence.end_with?('.', '!', '?') ? first_sentence : "#{first_sentence}."
        else
          "#{first_sentence[0, MAX_ONELINER_LENGTH - 3].strip}..."
        end
      end

      def format_date_range(comments)
        return nil if comments.empty?

        dates = comments.map(&:created_at).compact.sort
        return nil if dates.empty?

        first_date = dates.first.strftime('%Y-%m-%d')
        last_date = dates.last.strftime('%Y-%m-%d')

        first_date == last_date ? first_date : "#{first_date} to #{last_date}"
      end

      def extract_highlights(comments)
        highlights = []

        # Get first and last comment summaries
        if comments.size >= 1
          first = comments.min_by(&:created_at)
          highlights << truncate_highlight("#{first.author || 'unknown'}: #{first.content}")
        end

        if comments.size >= 2
          last = comments.max_by(&:created_at)
          # Avoid duplicate when first and last are the same (e.g., same timestamp)
          unless last == first
            highlights << truncate_highlight("#{last.author || 'unknown'}: #{last.content}")
          end
        end

        # Look for key phrases in middle comments
        if comments.size > 2
          middle_comments = comments[1..-2]
          key_phrases = %w[resolved fixed decided concluded agreed]

          middle_comments.each do |comment|
            next unless key_phrases.any? { |phrase| comment.content.downcase.include?(phrase) }

            highlights << truncate_highlight("#{comment.author}: #{comment.content}")
            break if highlights.size >= 4
          end
        end

        highlights.first(4)
      end

      def truncate_highlight(text)
        return text if text.length <= 80

        "#{text[0, 77]}..."
      end
    end
  end
end
