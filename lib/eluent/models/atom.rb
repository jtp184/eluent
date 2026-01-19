# frozen_string_literal: true

module Eluent
  module Models
    # Core work item entity (task, bug, feature, etc.)
    class Atom
      include Validations
      extend Forwardable

      attr_accessor :id, :title, :description, :status, :issue_type, :priority,
                    :labels, :assignee, :parent_id, :defer_until, :close_reason,
                    :created_at, :updated_at, :metadata

      def_delegators :issue_type, :abstract?

      def initialize(
        id:,
        title:,
        description: nil,
        status: :open,
        issue_type: :task,
        priority: 2,
        labels: [],
        created_at: Time.now.utc,
        updated_at: Time.now.utc,
        metadata: {},
        assignee: nil,
        parent_id: nil,
        defer_until: nil,
        close_reason: nil
      )
        @id = id
        @title = validate_title(title)
        @description = validate_content(description)
        @status = validate_status(status)
        @issue_type = validate_issue_type(issue_type)
        @priority = validate_priority(priority)
        @labels = Set.new(Array(labels))
        @assignee = assignee
        @parent_id = parent_id
        @defer_until = parse_time(defer_until)
        @close_reason = close_reason
        @created_at = parse_time(created_at)
        @updated_at = parse_time(updated_at)
        @metadata = metadata
      end

      Status.all.each do |status_name, status|
        define_method "#{status_name}?" do
          self.status == status
        end
      end

      IssueType.all.each do |type_name, issue_type|
        define_method "#{type_name}?" do
          self.issue_type == issue_type
        end
      end

      def root?
        parent_id.nil?
      end

      def child?
        !root?
      end

      def defer_past?
        defer_until < Time.now.utc if defer_until
      end

      def defer_future?
        deferred? && defer_until && defer_until > Time.now.utc
      end

      def to_h
        {
          _type: 'atom',
          id: id,
          title: title,
          description: description,
          status: status.to_s,
          issue_type: issue_type.to_s,
          priority: priority,
          labels: labels.to_a,
          assignee: assignee,
          parent_id: parent_id,
          defer_until: defer_until&.iso8601,
          close_reason: close_reason,
          created_at: created_at&.iso8601,
          updated_at: updated_at&.iso8601,
          metadata: metadata
        }
      end

      def ==(other)
        other.is_a?(Atom) && id == other.id
      end

      def eql?(other)
        self == other
      end

      def hash
        id.hash
      end
    end
  end
end
