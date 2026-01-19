# frozen_string_literal: true

module Eluent
  module Lifecycle
    # Calculates ready work items with various sort policies
    class ReadinessCalculator
      SORT_POLICIES = %i[priority oldest hybrid].freeze
      HYBRID_RECENT_HOURS = 48

      def initialize(indexer:, blocking_resolver:)
        @indexer = indexer
        @blocking_resolver = blocking_resolver
      end

      # Query ready items with filtering and sorting
      # @param sort [Symbol] Sort policy (:priority, :oldest, :hybrid)
      # @param type [String, Symbol, nil] Filter by issue type
      # @param exclude_types [Array<String, Symbol>] Types to exclude
      # @param assignee [String, nil] Filter by assignee
      # @param labels [Array<String>] Filter by labels (all must match)
      # @param priority [Integer, nil] Filter by priority
      # @param include_abstract [Boolean] Include abstract types (epic, formula)
      def ready_items(
        sort: :priority,
        type: nil,
        exclude_types: [],
        assignee: nil,
        labels: [],
        priority: nil,
        include_abstract: false
      )
        blocking_resolver.clear_cache

        items = indexer.all_atoms.select do |atom|
          ready_for_work?(atom, include_abstract: include_abstract) &&
            matches_filters?(atom, type: type, exclude_types: exclude_types,
                                   assignee: assignee, labels: labels, priority: priority)
        end

        sort_items(items, policy: sort)
      end

      private

      attr_reader :indexer, :blocking_resolver

      def ready_for_work?(atom, include_abstract:)
        blocking_resolver.ready?(atom, include_abstract: include_abstract)
      end

      def matches_filters?(atom, type:, exclude_types:, assignee:, labels:, priority:)
        return false if type && atom.issue_type.name != normalize_type(type)
        return false if exclude_types.any? { |t| atom.issue_type.name == normalize_type(t) }
        return false if assignee && atom.assignee != assignee
        return false if priority && atom.priority != priority.to_i
        return false unless labels.empty? || labels_match?(atom, labels)

        true
      end

      def labels_match?(atom, required_labels)
        required_labels.all? { |label| atom.labels.include?(label) }
      end

      def normalize_type(type)
        case type
        when Models::IssueType then type.name
        when Symbol then type
        when String then type.to_sym
        else type.respond_to?(:to_sym) ? type.to_sym : type
        end
      end

      def sort_items(items, policy:)
        case policy.to_sym
        when :priority, :default then sort_by_priority(items)
        when :oldest then sort_by_oldest(items)
        when :hybrid then sort_by_hybrid(items)
        end
      end

      # Sort by priority (0=highest), then by creation date
      def sort_by_priority(items)
        items.sort_by { |atom| [atom.priority, atom.created_at] }
      end

      # Sort by creation date ascending (oldest first)
      def sort_by_oldest(items)
        items.sort_by(&:created_at)
      end

      # Hybrid: Recent items (within 48h) by priority, older items by age
      # This prevents starvation of older items
      def sort_by_hybrid(items)
        cutoff = Time.now.utc - (HYBRID_RECENT_HOURS * 3600)

        recent, older = items.partition { |atom| atom.created_at > cutoff }

        sorted_recent = sort_by_priority(recent)
        sorted_older = sort_by_oldest(older)

        # Concatenate: older items first to prevent starvation, then recent by priority
        sorted_older + sorted_recent
      end
    end
  end
end
