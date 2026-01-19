# frozen_string_literal: true

module Eluent
  module Compaction
    # Performs tier-based compaction of old closed items
    class Compactor
      TIER_THRESHOLDS = {
        1 => 30,  # 30 days
        2 => 90   # 90 days
      }.freeze

      def initialize(repository:)
        @repository = repository
        @summarizer = Summarizer.new(repository: repository)
      end

      def find_candidates(tier:, cutoff_date: nil)
        threshold_days = TIER_THRESHOLDS[tier]
        raise CompactionError, "Unknown compaction tier: #{tier}" unless threshold_days

        cutoff = cutoff_date || (Time.now.utc - (threshold_days * 24 * 60 * 60))

        repository.all_atoms.select do |atom|
          eligible_for_compaction?(atom, tier: tier, cutoff: cutoff)
        end
      end

      def compact(atom_id, tier:)
        atom = repository.find_atom(atom_id)
        raise Registry::IdNotFoundError, atom_id unless atom

        unless eligible_for_compaction?(atom, tier: tier, cutoff: Time.now.utc)
          raise CompactionError, "Atom #{atom_id} is not eligible for tier #{tier} compaction"
        end

        summary = summarizer.generate_compaction_summary(atom, tier: tier)
        apply_compaction(atom, summary, tier: tier)

        CompactionResult.new(
          atom_id: atom.id,
          tier: tier,
          summary: summary
        )
      end

      def compact_all(tier:, cutoff_date: nil, preview: false)
        candidates = find_candidates(tier: tier, cutoff_date: cutoff_date)

        return preview_results(candidates, tier) if preview

        results = candidates.map do |atom|
          compact(atom.id, tier: tier)
        rescue StandardError => e
          CompactionResult.new(
            atom_id: atom.id,
            tier: tier,
            error: e.message
          )
        end

        CompactionBatchResult.new(results: results, tier: tier)
      end

      def preview(atom_id, tier:)
        atom = repository.find_atom(atom_id)
        raise Registry::IdNotFoundError, atom_id unless atom

        summary = summarizer.generate_compaction_summary(atom, tier: tier)

        {
          atom_id: atom.id,
          tier: tier,
          current: {
            description_length: atom.description&.length || 0,
            comment_count: repository.comments_for(atom.id).size
          },
          after: {
            description_length: summary[:description]&.length || 0,
            comment_count: summary[:comments] ? 1 : 0
          },
          summary: summary
        }
      end

      private

      attr_reader :repository, :summarizer

      def eligible_for_compaction?(atom, tier:, cutoff:)
        return false unless atom.closed? || atom.discard?
        return false unless atom.updated_at && atom.updated_at < cutoff

        current_tier = atom.metadata&.dig('compaction_tier') || 0
        current_tier < tier
      end

      def apply_compaction(atom, summary, tier:)
        # Update atom description
        atom.description = summary[:description]
        atom.metadata ||= {}
        atom.metadata['compaction_tier'] = tier
        atom.metadata['compacted_at'] = summary[:compacted_at]
        atom.metadata['original_description_length'] = summary[:original_description_length]
        atom.metadata['original_comment_count'] = summary[:original_comment_count]

        repository.update_atom(atom)

        # Compact comments
        repository.compact_comments(atom.id, summary[:comments]) if tier == 1

        # For tier 2, remove all comments
        repository.compact_comments(atom.id, nil) if tier == 2
      end

      def preview_results(candidates, tier)
        previews = candidates.map do |atom|
          preview(atom.id, tier: tier)
        end

        {
          tier: tier,
          candidate_count: candidates.size,
          total_description_bytes_before: previews.sum { |p| p[:current][:description_length] },
          total_description_bytes_after: previews.sum { |p| p[:after][:description_length] },
          total_comments_before: previews.sum { |p| p[:current][:comment_count] },
          total_comments_after: previews.sum { |p| p[:after][:comment_count] },
          candidates: previews
        }
      end
    end

    # Result of compacting a single atom
    class CompactionResult
      attr_reader :atom_id, :tier, :summary, :error

      def initialize(atom_id:, tier:, summary: nil, error: nil)
        @atom_id = atom_id
        @tier = tier
        @summary = summary
        @error = error
      end

      def success?
        error.nil?
      end

      def to_h
        hash = { atom_id: atom_id, tier: tier, success: success? }
        hash[:summary] = summary if summary
        hash[:error] = error if error
        hash
      end
    end

    # Result of batch compaction
    class CompactionBatchResult
      attr_reader :results, :tier

      def initialize(results:, tier:)
        @results = results
        @tier = tier
      end

      def success_count
        results.count(&:success?)
      end

      def error_count
        results.count { |r| !r.success? }
      end

      def to_h
        {
          tier: tier,
          total: results.size,
          success_count: success_count,
          error_count: error_count,
          results: results.map(&:to_h)
        }
      end
    end
  end
end
