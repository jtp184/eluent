# frozen_string_literal: true

require 'json'
require 'fileutils'

module Eluent
  module Registry
    # Cross-repo registry for managing multiple repositories
    # Single responsibility: track registered repositories
    class RepoRegistry
      REGISTRY_PATH = File.expand_path('~/.eluent/repos.jsonl')

      Entry = Struct.new(:name, :path, :remote, :registered_at, keyword_init: true) do
        def to_h
          {
            name: name,
            path: path,
            remote: remote,
            registered_at: registered_at&.iso8601
          }
        end
      end

      def initialize(registry_path: REGISTRY_PATH)
        @registry_path = registry_path
        @entries = nil
      end

      def register(name:, path:, remote: nil)
        load_entries

        # Remove existing entry with same name or path
        entries.reject! { |e| e.name == name || e.path == path }

        entry = Entry.new(
          name: name,
          path: File.expand_path(path),
          remote: remote,
          registered_at: Time.now.utc
        )

        entries << entry
        save_entries

        entry
      end

      def unregister(name)
        load_entries

        found = entries.find { |e| e.name == name }
        return nil unless found

        entries.delete(found)
        save_entries

        found
      end

      def find(name)
        load_entries
        entries.find { |e| e.name == name }
      end

      def all
        load_entries
        entries.dup
      end

      def path_for(name)
        entry = find(name)
        entry&.path
      end

      def find_by_path(path)
        load_entries
        expanded = File.expand_path(path)
        entries.find { |e| e.path == expanded }
      end

      def exists?(name)
        !find(name).nil?
      end

      private

      attr_reader :registry_path
      attr_accessor :entries

      def load_entries
        return if @entries

        @entries = []
        return unless File.exist?(registry_path)

        File.foreach(registry_path) do |line|
          next if line.strip.empty?

          data = JSON.parse(line, symbolize_names: true)
          @entries << Entry.new(
            name: data[:name],
            path: data[:path],
            remote: data[:remote],
            registered_at: parse_time(data[:registered_at])
          )
        rescue JSON::ParserError
          # Skip malformed lines
        end
      end

      def save_entries
        ensure_registry_dir

        lines = entries.map { |e| JSON.generate(e.to_h) }
        content = lines.empty? ? '' : lines.join("\n") << "\n"

        # Atomic write
        temp_path = "#{registry_path}.tmp"
        File.write(temp_path, content)
        File.rename(temp_path, registry_path)
      end

      def ensure_registry_dir
        FileUtils.mkdir_p(File.dirname(registry_path))
      end

      def parse_time(value)
        case value
        when Time then value.utc
        when String then Time.parse(value).utc
        when nil then nil
        end
      end
    end
  end
end
