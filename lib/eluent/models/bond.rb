# frozen_string_literal: true

module Eluent
  module Models
    # Dependency relationship between two atoms
    class Bond
      extend Forwardable

      attr_accessor :source_id, :target_id, :dependency_type, :created_at, :metadata

      def_delegators :dependency_type, :blocking?

      def initialize(
        source_id:,
        target_id:,
        dependency_type: :blocks,
        created_at: Time.now.utc,
        metadata: {}
      )
        @source_id = source_id
        @target_id = target_id
        @dependency_type = validate_dependency_type(dependency_type)
        @created_at = parse_time(created_at)
        @metadata = metadata

        validate_not_self_reference
      end

      DependencyType.all.each do |dep_name, dep|
        define_method("#{dep_name}?") do
          dependency_type == dep
        end
      end

      def to_h
        {
          _type: 'bond',
          source_id: source_id,
          target_id: target_id,
          dependency_type: dependency_type,
          created_at: created_at&.iso8601,
          metadata: metadata
        }
      end

      def ==(other)
        other.is_a?(Bond) &&
          source_id == other.source_id &&
          target_id == other.target_id &&
          dependency_type == other.dependency_type
      end

      def eql?(other)
        self == other
      end

      def hash
        [source_id, target_id, dependency_type].hash
      end

      # Unique key for deduplication during sync
      def key
        "#{source_id}.#{target_id}.#{dependency_type}"
      end
    end
  end
end
