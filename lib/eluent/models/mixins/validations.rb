# frozen_string_literal: true

require 'time'

module Eluent
  module Models
    class ValidationError < Error; end
    class SelfReferenceError < Error; end

    # Validators for fields
    module Validations
      TITLE_MAX_LENGTH = 500
      CONTENT_MAX_LENGTH = 65_536

      private

      def validate_title(title)
        return nil if title.nil?

        title.to_s.then do |t|
          if t.length > TITLE_MAX_LENGTH
            warn "el: warning: title truncated to #{TITLE_MAX_LENGTH} characters"
            t = t[0, TITLE_MAX_LENGTH]
          end
          validate_utf8(t)
        end
      end

      def validate_content(content)
        return nil if content.nil?

        content.to_s.then do |d|
          raise ValidationError, "content exceeds #{CONTENT_MAX_LENGTH} characters" if d.length > CONTENT_MAX_LENGTH

          validate_utf8(d)
        end
      end

      def validate_status(status)
        status.to_sym.then do |s|
          Status[s]
        rescue KeyError
          raise ValidationError, "invalid status: #{status}"
        end
      end

      def validate_issue_type(issue_type)
        issue_type.to_sym.then do |t|
          IssueType[t]
        rescue KeyError
          raise ValidationError,
                "invalid issue_type: #{issue_type}. Valid: #{IssueType.all.keys.map(&:to_s).join(', ')}"
        end
      end

      def validate_priority(priority)
        Integer(priority)
      rescue ArgumentError
        raise ValidationError, "priority must be integer, got: #{priority}"
      end

      def validate_utf8(text)
        text.then do |t|
          unless t.valid_encoding? && t.encoding == Encoding::UTF_8
            t = t.encode('UTF-8', invalid: :replace, undef: :replace)
          end

          t.unicode_normalize(:nfc)
        end
      end

      def parse_time(value)
        case value
        when Time then value.utc
        when String then Time.parse(value).utc
        when nil then nil
        else raise ValidationError, "invalid time value: #{value}"
        end
      end

      def validate_not_self_reference(source_id:, target_id:)
        return unless source_id && target_id && source_id == target_id

        raise SelfReferenceError, "cannot depend on itself: #{source_id}"
      end

      def validate_dependency_type(type)
        type.to_sym.then do |t|
          DependencyType[t]
        rescue KeyError
          raise ValidationError, "invalid dependency_type: #{type}"
        end
      end

    end
  end
end
