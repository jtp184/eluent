# frozen_string_literal: true

require 'json'
require 'fileutils'

module Eluent
  module Storage
    # Low-level file operations with locking and atomic writes
    # Single responsibility: safe file I/O for JSONL files
    module FileOperations
      module_function

      # Append a record to a JSONL file with exclusive lock
      def append_record(path, record)
        File.open(path, 'a') do |file|
          file.flock(File::LOCK_EX)
          file.puts(serialize_record(record))
          file.flock(File::LOCK_UN)
        end
      end

      # Rewrite file atomically, yielding records for transformation
      def rewrite_file(path)
        return unless File.exist?(path)

        records = read_all_records(path)
        records = yield(records)
        write_records_atomically(path, records)
      end

      # Read all records from a JSONL file
      def read_all_records(path)
        return [] unless File.exist?(path)

        File.foreach(path).filter_map do |line|
          parse_line(line.strip)
        end
      end

      # Stream records from a file, yielding each parsed record
      def each_record(path)
        return enum_for(:each_record, path) unless block_given?

        File.foreach(path) do |line|
          record = parse_line(line.strip)
          yield record if record
        end
      end

      # Find first record matching a predicate
      def find_record(path, &)
        each_record(path).find(&)
      end

      # Check if file contains a record matching predicate
      def record_exists?(path, &)
        !find_record(path, &).nil?
      end

      # Write records atomically using temp file + rename
      def write_records_atomically(path, records)
        temp_path = "#{path}.tmp"
        lines = records.map { |record| serialize_record(record) }
        content = lines.empty? ? '' : lines.join("\n") << "\n"

        File.write(temp_path, content)
        File.rename(temp_path, path)
      end

      # Serialize a record (handles both Hash and objects with #to_json)
      def serialize_record(record)
        case record
        when String then record
        when Hash then JSON.generate(record)
        else record.to_json
        end
      end

      def parse_line(line)
        return nil if line.empty?

        JSON.parse(line, symbolize_names: true)
      rescue JSON::ParserError => e
        warn "el: warning: skipping malformed line: #{e.message}"
        nil
      end
    end
  end
end
