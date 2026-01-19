# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module Eluent
  module Sync
    # Manages .sync-state file for tracking sync status.
    # Single responsibility: persist and retrieve sync state.
    #
    # Fields:
    #   last_sync_at  - Timestamp of the last successful sync operation.
    #   base_commit   - The common ancestor commit used for 3-way merge.
    #                   After sync, this becomes the new merge base for next sync.
    #   local_head    - The local commit SHA after last sync completed.
    #   remote_head   - The remote commit SHA that was merged in last sync.
    class SyncState
      attr_reader :last_sync_at, :base_commit, :local_head, :remote_head

      def initialize(paths:)
        @paths = paths
        @last_sync_at = nil
        @base_commit = nil
        @local_head = nil
        @remote_head = nil
      end

      def load
        return self unless exists?

        data = JSON.parse(File.read(sync_state_file), symbolize_names: true)
        @last_sync_at = parse_time(data[:last_sync_at])
        @base_commit = data[:base_commit]
        @local_head = data[:local_head]
        @remote_head = data[:remote_head]
        self
      rescue JSON::ParserError => e
        warn "el: warning: corrupted sync state, resetting: #{e.message}"
        reset!
      end

      def save
        FileUtils.mkdir_p(File.dirname(sync_state_file))
        File.write(sync_state_file, JSON.pretty_generate(to_h) << "\n")
        self
      end

      def update(last_sync_at:, base_commit:, local_head:, remote_head:)
        @last_sync_at = last_sync_at
        @base_commit = base_commit
        @local_head = local_head
        @remote_head = remote_head
        self
      end

      def exists?
        File.exist?(sync_state_file)
      end

      def reset!
        @last_sync_at = nil
        @base_commit = nil
        @local_head = nil
        @remote_head = nil
        File.delete(sync_state_file) if exists?
        self
      end

      def to_h
        {
          last_sync_at: last_sync_at&.iso8601,
          base_commit: base_commit,
          local_head: local_head,
          remote_head: remote_head
        }
      end

      private

      attr_reader :paths

      def sync_state_file = paths.sync_state_file

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
