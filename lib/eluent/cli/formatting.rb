# frozen_string_literal: true

module Eluent
  module CLI
    # Shared formatting helpers for CLI commands
    module Formatting
      TYPE_COLORS = {
        'feature' => :green,
        'bug' => :red,
        'task' => :blue,
        'artifact' => :magenta,
        'epic' => :yellow,
        'formula' => :cyan
      }.freeze

      STATUS_COLORS = {
        'open' => :green,
        'in_progress' => :yellow,
        'blocked' => :red,
        'deferred' => :cyan,
        'closed' => :dim,
        'discard' => :dim
      }.freeze

      PRIORITY_COLORS = {
        0 => :red,
        1 => :yellow,
        2 => :white,
        3 => :cyan,
        4 => :dim,
        5 => :dim
      }.freeze

      private

      def format_type(type, upcase: false)
        display = upcase ? type.upcase : type
        @pastel.decorate(display, TYPE_COLORS[type] || :white)
      end

      def format_status(status)
        @pastel.decorate(status, STATUS_COLORS[status] || :white)
      end

      def format_priority(priority)
        @pastel.decorate(priority.to_s, PRIORITY_COLORS[priority] || :white)
      end

      def format_priority_with_label(priority)
        labels = %w[Critical High Normal Low Minor Trivial]
        label = labels[priority] || priority.to_s
        colors = { 0 => :red, 1 => :yellow, 2 => :white }
        @pastel.decorate("#{priority} (#{label})", colors[priority] || :dim)
      end

      def truncate(text, max_length:)
        return '' unless text

        text.length > max_length ? "#{text[0, max_length - 3]}..." : text
      end
    end
  end
end
