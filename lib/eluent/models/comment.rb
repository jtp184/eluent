# frozen_string_literal: true

require 'digest'

module Eluent
  module Models
    # Append-only discussion item attached to an atom
    class Comment
      include Validations

      attr_accessor :id, :parent_id, :author, :content, :created_at, :updated_at

      def initialize(
        id:,
        parent_id:,
        author:,
        content:,
        created_at: Time.now.utc,
        updated_at: Time.now.utc
      )
        @id = id
        @parent_id = parent_id
        @author = author
        @content = validate_content(content)
        @created_at = parse_time(created_at) || Time.now.utc
        @updated_at = parse_time(updated_at) || Time.now.utc
      end

      def to_h
        {
          _type: 'comment',
          id: id,
          parent_id: parent_id,
          author: author,
          content: content,
          created_at: created_at&.iso8601,
          updated_at: updated_at&.iso8601
        }
      end

      def ==(other)
        other.is_a?(Comment) && id == other.id
      end

      def eql?(other)
        self == other
      end

      def hash
        id.hash
      end

      # Unique hash for deduplication during sync
      # Key: SHA256(parent_id + author + created_at + content) -> 16-char hex prefix
      def dedup_key
        data = "#{parent_id}#{author}#{created_at&.iso8601}#{content}"
        Digest::SHA256.hexdigest(data)[0, 16]
      end
    end
  end
end
