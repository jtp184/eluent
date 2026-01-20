# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module Eluent
  module Sync
    # Persists ledger sync metadata to disk for recovery and offline support.
    #
    # Tracks:
    # - Last pull/push timestamps for determining staleness
    # - Current ledger HEAD SHA for detecting remote changes
    # - Validity flag indicating whether local state is consistent
    # - Offline claims made while disconnected for later reconciliation
    #
    # State is stored as JSON at `~/.eluent/<repo>/.ledger-sync-state` with
    # atomic writes (temp file + rename) and file locking for concurrent access.
    #
    # @example
    #   state = LedgerSyncState.new(global_paths: paths)
    #   state.load
    #   state.update_pull(head_sha: 'abc123')
    #   state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: Time.now)
    #   state.save
    #
    class LedgerSyncState
      # Schema version for state file format. Increment when adding/changing fields.
      VERSION = 1

      # Maximum number of offline claims to retain. Oldest claims are dropped when exceeded.
      MAX_OFFLINE_CLAIMS = 1000

      # Maximum length for string fields to prevent unbounded storage.
      MAX_SHA_LENGTH = 64
      MAX_ATOM_ID_LENGTH = 256
      MAX_AGENT_ID_LENGTH = 256

      attr_reader :last_pull_at, :last_push_at, :ledger_head, :offline_claims, :schema_version

      # Returns true if the local ledger state is consistent and usable.
      # Set to true after a successful pull, false on corruption or reset.
      def valid? = @valid

      def initialize(global_paths:, clock: Time)
        @global_paths = global_paths
        @clock = clock
        reset_state!
      end

      # Loads state from the state file.
      #
      # Returns self with populated fields. If the file doesn't exist or is
      # corrupted, resets to a fresh state and logs a warning.
      #
      # @return [LedgerSyncState] self
      def load
        return self unless File.exist?(state_file)

        with_lock(File::LOCK_SH) do
          content = File.read(state_file, encoding: 'UTF-8')
          data = JSON.parse(content, symbolize_names: true)
          load_from_hash(data)
        end
        self
      rescue JSON::ParserError, Errno::ENOENT, Encoding::InvalidByteSequenceError,
             Encoding::UndefinedConversionError => e
        warn "el: warning: corrupted ledger sync state, resetting: #{e.message}"
        reset!
      end

      # Persists current state to the state file atomically.
      #
      # Uses temp file + rename for atomicity and file locking for
      # cross-process safety.
      #
      # @return [LedgerSyncState] self
      # @raise [LedgerSyncStateError] if the file cannot be written (permissions, disk full, etc.)
      def save
        FileUtils.mkdir_p(File.dirname(state_file))

        with_lock(File::LOCK_EX) do
          temp_file = "#{state_file}.#{Process.pid}.#{Thread.current.object_id}.tmp"
          begin
            File.write(temp_file, JSON.pretty_generate(to_h) << "\n", encoding: 'UTF-8')
            File.rename(temp_file, state_file)
          rescue StandardError
            FileUtils.rm_f(temp_file)
            raise
          end
        end
        self
      rescue Errno::EACCES, Errno::EROFS => e
        raise LedgerSyncStateError, "Cannot write ledger sync state: #{e.message}"
      rescue Errno::ENOSPC, Errno::EDQUOT => e
        raise LedgerSyncStateError, "Disk full or quota exceeded: #{e.message}"
      end

      # Records a successful pull operation.
      #
      # @param head_sha [String] the commit SHA after pulling
      # @return [LedgerSyncState] self
      # @raise [ArgumentError] if head_sha is nil or empty
      def update_pull(head_sha:)
        validate_head_sha!(head_sha)
        @last_pull_at = clock.now.utc
        @ledger_head = normalize_sha(head_sha)
        @valid = true
        self
      end

      # Records a successful push operation.
      #
      # @param head_sha [String] the commit SHA after pushing
      # @return [LedgerSyncState] self
      # @raise [ArgumentError] if head_sha is nil or empty
      def update_push(head_sha:)
        validate_head_sha!(head_sha)
        @last_push_at = clock.now.utc
        @ledger_head = normalize_sha(head_sha)
        self
      end

      # Records a claim made while offline for later reconciliation.
      #
      # @param atom_id [String] the atom that was claimed
      # @param agent_id [String] the agent that made the claim
      # @param claimed_at [Time] when the claim was made
      # @return [LedgerSyncState] self
      # @raise [ArgumentError] if atom_id or agent_id is nil/empty, or claimed_at is not a Time
      def record_offline_claim(atom_id:, agent_id:, claimed_at:)
        validate_claim_params!(atom_id: atom_id, agent_id: agent_id, claimed_at: claimed_at)

        normalized_atom_id = normalize_string(atom_id, MAX_ATOM_ID_LENGTH)
        normalized_agent_id = normalize_string(agent_id, MAX_AGENT_ID_LENGTH)

        claim = OfflineClaim.new(
          atom_id: normalized_atom_id,
          agent_id: normalized_agent_id,
          claimed_at: claimed_at.utc
        )

        @offline_claims.reject! { |c| c.atom_id == normalized_atom_id }
        @offline_claims << claim

        trim_offline_claims!
        self
      end

      # Removes an offline claim (e.g., after successful reconciliation).
      #
      # @param atom_id [String] the atom to clear
      # @return [LedgerSyncState] self
      def clear_offline_claim(atom_id:)
        return self if atom_id.nil?

        normalized = normalize_string(atom_id.to_s, MAX_ATOM_ID_LENGTH)
        @offline_claims.reject! { |c| c.atom_id == normalized }
        self
      end

      # Returns true if there are pending offline claims to reconcile.
      #
      # @return [Boolean]
      def offline_claims? = !offline_claims.empty?

      # Clears all state and deletes the state file.
      #
      # @return [LedgerSyncState] self
      def reset!
        reset_state!
        FileUtils.rm_f(state_file)
        self
      end

      # Returns true if the state file exists.
      #
      # @return [Boolean]
      def exists? = File.exist?(state_file)

      # Returns a hash representation suitable for JSON serialization.
      #
      # @return [Hash]
      def to_h
        {
          schema_version: schema_version,
          last_pull_at: last_pull_at&.iso8601,
          last_push_at: last_push_at&.iso8601,
          ledger_head: ledger_head,
          valid: valid?,
          offline_claims: serialize_offline_claims
        }
      end

      # Marks the state as invalid (e.g., after detecting corruption).
      #
      # @return [LedgerSyncState] self
      def invalidate!
        @valid = false
        self
      end

      private

      attr_reader :global_paths, :clock

      def state_file = global_paths.ledger_sync_state_file

      def reset_state!
        @last_pull_at = nil
        @last_push_at = nil
        @ledger_head = nil
        @valid = false
        @offline_claims = []
        @schema_version = VERSION
      end

      def load_from_hash(data)
        file_version = data[:schema_version] || 1

        if file_version > VERSION
          raise LedgerSyncStateError,
                "Schema version #{file_version} is newer than supported (#{VERSION}). " \
                'Please upgrade eluent.'
        end

        @schema_version = file_version
        @last_pull_at = parse_time(data[:last_pull_at])
        @last_push_at = parse_time(data[:last_push_at])
        @ledger_head = data[:ledger_head]
        # :worktree_valid is the legacy field name from schema version 0
        @valid = data.fetch(:valid) { data[:worktree_valid] || false }
        @offline_claims = Array(data[:offline_claims]).map { |c| deserialize_claim(c) }

        migrate_schema! if schema_version < VERSION
      end

      # Upgrades in-memory state from an older schema version to the current version.
      # Add field migrations here when VERSION is incremented.
      def migrate_schema!
        # Example for future migrations:
        # if schema_version < 2
        #   @new_field ||= default_value
        # end

        @schema_version = VERSION
      end

      def deserialize_claim(data)
        OfflineClaim.new(
          atom_id: data[:atom_id],
          agent_id: data[:agent_id],
          claimed_at: parse_time(data[:claimed_at])
        )
      end

      def serialize_offline_claims = offline_claims.map(&:to_h)

      def parse_time(value)
        case value
        when Time then value.utc
        when String
          return nil if value.empty?

          Time.parse(value).utc
        end
      rescue ArgumentError
        # Invalid time string, treat as missing
        nil
      end

      def validate_head_sha!(sha)
        raise ArgumentError, 'head_sha is required' if sha.nil?
        raise ArgumentError, 'head_sha cannot be empty' if sha.to_s.strip.empty?
      end

      def normalize_sha(sha)
        sha.to_s.strip.slice(0, MAX_SHA_LENGTH)
      end

      def validate_claim_params!(atom_id:, agent_id:, claimed_at:)
        raise ArgumentError, 'atom_id is required' if atom_id.nil?
        raise ArgumentError, 'atom_id cannot be empty' if atom_id.to_s.strip.empty?
        raise ArgumentError, 'agent_id is required' if agent_id.nil?
        raise ArgumentError, 'agent_id cannot be empty' if agent_id.to_s.strip.empty?
        raise ArgumentError, 'claimed_at must be a Time' unless claimed_at.is_a?(Time)
      end

      def normalize_string(value, max_length)
        value.to_s.strip.slice(0, max_length)
      end

      def trim_offline_claims!
        return if offline_claims.size <= MAX_OFFLINE_CLAIMS

        dropped = offline_claims.size - MAX_OFFLINE_CLAIMS
        warn "el: warning: offline claims limit reached, dropping #{dropped} oldest claims"
        @offline_claims = offline_claims.last(MAX_OFFLINE_CLAIMS)
      end

      # Acquires a file lock for thread/process-safe access.
      #
      # Uses a separate lock file rather than locking the state file directly because:
      # 1. Readers can acquire the lock while writers hold the state file open
      # 2. The lock file persists even if atomic rename replaces the state file
      # 3. Network filesystems may not support flock on regularly-modified files
      #
      # Falls back to no-op if flock is not supported (e.g., some network filesystems).
      def with_lock(lock_type)
        FileUtils.mkdir_p(File.dirname(lock_file))

        File.open(lock_file, File::RDWR | File::CREAT) do |f|
          begin
            f.flock(lock_type)
          rescue NotImplementedError
            # flock not supported (e.g., FakeFS in tests, some network filesystems)
          end
          yield
        end
      end

      def lock_file = global_paths.ledger_lock_file
    end

    # Raised for ledger sync state errors (corruption, version mismatch).
    class LedgerSyncStateError < Error; end

    # Represents a claim made while offline, pending reconciliation with the remote ledger.
    OfflineClaim = Data.define(:atom_id, :agent_id, :claimed_at) do
      # @return [Hash] JSON-serializable representation with ISO8601 timestamp
      def to_h = { atom_id: atom_id, agent_id: agent_id, claimed_at: claimed_at&.iso8601 }
    end
  end
end
