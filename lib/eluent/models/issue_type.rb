# frozen_string_literal: true

module Eluent
  module Models
    # Semantically distinct types of work items
    class IssueType
      include ExtendableCollection

      self.defaults = {
        feature: {},
        bug: {},
        task: {},
        artifact: {},
        epic: { abstract: true },
        formula: { abstract: true }
      }.freeze

      attr_reader :name, :abstract

      def initialize(name:, abstract: false)
        @name = name
        @abstract = abstract
      end

      def abstract?
        !!@abstract
      end

      def ==(other)
        other.is_a?(IssueType) && other.name == name
      end
    end
  end
end
