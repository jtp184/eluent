# frozen_string_literal: true

require 'fileutils'
require 'time'
require_relative 'concerns/ledger_worktree'
require_relative 'concerns/ledger_atom_operations'

module Eluent
  module Sync
    # Coordinates multi-agent work via a dedicated git branch for claim state.
    #
    # Maintains a separate git worktree that tracks the `.eluent/` directory on
    # a dedicated orphan branch, enabling fast, conflict-free syncing of atom
    # claim state without affecting the main working tree.
    #
    # Architecture:
    #   - Remote: `eluent-sync` orphan branch containing only `.eluent/` contents
    #   - Local: Git worktree at `~/.eluent/<repo>/.sync-worktree/`
    #   - State: Sync metadata at `~/.eluent/<repo>/.ledger-sync-state`
    #
    # Claim semantics use optimistic locking: pull, claim locally, push. On push
    # conflict (another agent pushed first), retry from pull with exponential
    # backoff until success or max retries exceeded.
    #
    # @example Basic usage
    #   syncer = LedgerSyncer.new(
    #     repository: repo,
    #     git_adapter: adapter,
    #     global_paths: paths,
    #     remote: 'origin'
    #   )
    #   syncer.setup!
    #   result = syncer.claim_and_push(atom_id: 'TSV4', agent_id: 'agent-1')
    #
    # @see LEDGER_BRANCH.md for full implementation details
    # rubocop:disable Metrics/ClassLength -- Core syncer with many related operations; extracting more would hurt cohesion
    class LedgerSyncer
      include Concerns::LedgerWorktree
      include Concerns::LedgerAtomOperations

      # Default branch name for the orphan sync branch
      LEDGER_BRANCH = 'eluent-sync'

      # Retry configuration for push conflicts (exponential backoff with jitter)
      MAX_RETRIES = 5
      BASE_BACKOFF_MS = 100
      MAX_BACKOFF_MS = 5000
      JITTER_FACTOR = 0.2 # ±20% randomization to prevent thundering herd

      # Directory containing atom and agent state files
      LEDGER_DIR = '.eluent'

      # Seconds per hour, for claim timeout calculations
      SECONDS_PER_HOUR = 3600
      private_constant :SECONDS_PER_HOUR

      # Frozen empty array for reconcile_offline_claims! placeholder
      EMPTY_ARRAY = [].freeze
      private_constant :EMPTY_ARRAY

      # Result of a claim operation.
      #
      # @!attribute success [Boolean] whether the claim succeeded
      # @!attribute error [String, nil] error message if failed
      # @!attribute claimed_by [String, nil] agent that holds the claim
      # @!attribute retries [Integer] number of retry attempts made
      # @!attribute offline_claim [Boolean] true if claimed while offline
      ClaimResult = Data.define(:success, :error, :claimed_by, :retries, :offline_claim) do
        def initialize(success:, error: nil, claimed_by: nil, retries: 0, offline_claim: false)
          super
        end
      end

      # Result of setup operation.
      #
      # @!attribute success [Boolean] whether setup succeeded
      # @!attribute error [String, nil] error message if failed
      # @!attribute created_branch [Boolean] true if branch was created
      # @!attribute created_worktree [Boolean] true if worktree was created
      SetupResult = Data.define(:success, :error, :created_branch, :created_worktree) do
        def initialize(success:, error: nil, created_branch: false, created_worktree: false)
          super
        end
      end

      # Result of sync operation.
      #
      # @!attribute success [Boolean] whether sync succeeded
      # @!attribute error [String, nil] error message if failed
      # @!attribute conflicts [Array<String>] atom IDs with merge conflicts
      # @!attribute changes_applied [Integer] number of changes synced
      SyncResult = Data.define(:success, :error, :conflicts, :changes_applied) do
        def initialize(success:, error: nil, conflicts: [], changes_applied: 0)
          super
        end
      end

      attr_reader :repository, :git_adapter, :global_paths, :remote, :max_retries, :branch,
                  :claim_timeout_hours

      def initialize(repository:, git_adapter:, global_paths:, remote: 'origin',
                     max_retries: MAX_RETRIES, branch: LEDGER_BRANCH, clock: Time,
                     claim_timeout_hours: nil)
        @repository = repository
        @git_adapter = git_adapter
        @global_paths = global_paths
        @remote = remote
        @max_retries = max_retries.to_i.clamp(1, 100)
        @branch = branch
        @clock = clock
        @claim_timeout_hours = normalize_claim_timeout(claim_timeout_hours)
      end

      # ------------------------------------------------------------------
      # State Checks
      # ------------------------------------------------------------------

      # Returns true if the syncer is configured and ready for operations.
      # Requires both a worktree and a branch (local or remote).
      def available?
        worktree_registered? && (local_branch_exists? || remote_branch_exists?)
      end

      # Returns true if the remote repository is reachable.
      # Used to determine whether to attempt network operations.
      def online?
        git_adapter.remote_branch_sha(remote: remote, branch: branch)
        true
      rescue GitError, GitTimeoutError
        false
      end

      # Returns true if the syncer is available and the worktree is valid.
      # A false result suggests setup! or recover_stale_worktree! may be needed.
      def healthy?
        available? && !worktree_stale?
      end

      # ------------------------------------------------------------------
      # Setup & Teardown
      # ------------------------------------------------------------------

      # Initializes the ledger sync infrastructure.
      #
      # Creates the orphan branch and worktree if they don't exist.
      # When starting fresh, seeds the worktree with any existing ledger
      # data from the main branch.
      #
      # @return [SetupResult] indicating what was created and any errors
      def setup!
        global_paths.ensure_directories!
        created_branch = ensure_branch!
        created_worktree = ensure_worktree!
        seed_from_main if created_worktree && ledger_dir_empty?

        SetupResult.new(success: true, created_branch: created_branch, created_worktree: created_worktree)
      rescue GitError, WorktreeError, BranchError, LedgerSyncerError => e
        SetupResult.new(success: false, error: e.message)
      end

      # Removes all local ledger sync resources.
      #
      # Cleans up the worktree and state files. Does NOT delete the remote
      # branch, so other agents can continue using it.
      #
      # @raise [LedgerSyncerError] if cleanup fails
      def teardown!
        remove_worktree_if_exists
        git_adapter.worktree_prune
        cleanup_state_files
        true
      rescue GitError, WorktreeError => e
        raise LedgerSyncerError, "Teardown failed: #{e.message}"
      end

      # ------------------------------------------------------------------
      # Core Operations
      # ------------------------------------------------------------------

      # Atomically claims an atom and pushes the change to the remote.
      #
      # Implements optimistic locking with retry:
      # 1. Pull latest ledger state
      # 2. Attempt local claim (may fail if already claimed)
      # 3. Push to remote (may fail if another agent pushed first)
      # 4. On push conflict, retry from step 1 with exponential backoff
      #
      # @param atom_id [String] the atom identifier to claim
      # @param agent_id [String] the agent claiming the atom
      # @return [ClaimResult] with success status, claimed_by, and retry count
      def claim_and_push(atom_id:, agent_id:)
        recover_stale_worktree! if worktree_stale?
        retries = 0

        loop do
          pull_result = pull_ledger
          return ClaimResult.new(success: false, error: pull_result.error, retries: retries) unless pull_result.success

          claim_result = attempt_claim(atom_id: atom_id, agent_id: agent_id)
          return claim_result.with(retries: retries) unless claim_result.success

          push_result = push_ledger
          return ClaimResult.new(success: true, claimed_by: agent_id, retries: retries) if push_result.success

          # Push failed (likely conflict) - retry with backoff
          retries += 1
          if retries >= max_retries
            return ClaimResult.new(success: false, error: 'Max retries exceeded', retries: retries)
          end

          sleep_with_backoff(retries)
        end
      rescue LedgerSyncerError => e
        ClaimResult.new(success: false, error: e.message, retries: retries || 0)
      end

      # Fetches and resets the worktree to match the remote ledger branch.
      #
      # Uses hard reset (not merge) to avoid conflicts - the ledger branch
      # is append-only so the remote is always authoritative.
      #
      # When `claim_timeout_hours` is configured, automatically releases
      # stale claims after pulling the latest state.
      def pull_ledger
        recover_stale_worktree! if worktree_stale?
        fetch_ledger_branch
        merge_or_reset_ledger
        auto_release_stale_claims

        SyncResult.new(success: true, changes_applied: 1)
      rescue GitError, BranchError, LedgerSyncerError => e
        SyncResult.new(success: false, error: "Pull failed: #{e.message}")
      end

      # Commits any pending changes and pushes to the remote.
      #
      # @return [SyncResult] with success status
      def push_ledger
        commit_ledger_changes
        git_adapter.push_branch(remote: remote, branch: branch)

        SyncResult.new(success: true, changes_applied: 1)
      rescue GitError, BranchError => e
        SyncResult.new(success: false, error: "Push failed: #{e.message}")
      end

      # Copies ledger files from the sync worktree to the main working directory.
      #
      # Use this to update the main branch's view of ledger state after
      # pulling remote changes.
      def sync_to_main
        src = worktree_ledger_dir
        dest = main_ledger_dir
        return SyncResult.new(success: false, error: 'Worktree ledger directory not found') unless Dir.exist?(src)

        FileUtils.mkdir_p(dest)
        sync_directory(src, dest)
        SyncResult.new(success: true, changes_applied: 1)
      rescue SystemCallError => e
        SyncResult.new(success: false, error: "Sync to main failed: #{e.message}")
      end

      # Copies ledger files from the main working directory to the sync worktree.
      #
      # Used during initial setup to bootstrap the sync branch with existing
      # ledger data. No-op if main has no ledger directory.
      def seed_from_main
        src = main_ledger_dir
        dest = worktree_ledger_dir
        return SyncResult.new(success: true) unless Dir.exist?(src)

        FileUtils.mkdir_p(dest)
        sync_directory(src, dest)
        commit_ledger_changes(message: 'Seed ledger from main branch')
        SyncResult.new(success: true, changes_applied: 1)
      rescue SystemCallError, GitError => e
        SyncResult.new(success: false, error: "Seed from main failed: #{e.message}")
      end

      # Releases a claim, returning the atom to 'open' status.
      #
      # Idempotent: succeeds if the atom is already open.
      #
      # @param atom_id [String] the atom identifier to release
      # @return [ClaimResult] with success status
      def release_claim(atom_id:)
        if atom_id.nil? || atom_id.to_s.strip.empty?
          return ClaimResult.new(success: false, error: 'atom_id cannot be nil or empty')
        end

        pull_result = pull_ledger
        return ClaimResult.new(success: false, error: pull_result.error) unless pull_result.success

        atom = find_atom_in_worktree(atom_id)
        return ClaimResult.new(success: false, error: "Atom not found: #{atom_id}") unless atom
        return ClaimResult.new(success: true) unless atom[:status] == 'in_progress'

        update_atom_in_worktree(atom_id, status: 'open', assignee: nil)
        commit_ledger_changes(message: "Release claim on #{atom_id}")

        push_result = push_ledger
        return ClaimResult.new(success: false, error: push_result.error) unless push_result.success

        ClaimResult.new(success: true)
      rescue LedgerSyncerError => e
        ClaimResult.new(success: false, error: e.message)
      end

      # Reconciles claims made while offline with the remote ledger.
      #
      # When agents work offline, they record claims locally. This method
      # attempts to push those claims when connectivity is restored, handling
      # conflicts where another agent claimed the same atom.
      #
      # @return [Array<Hash>] results for each reconciliation attempt (Phase 4)
      def reconcile_offline_claims!
        EMPTY_ARRAY
      end

      # ------------------------------------------------------------------
      # Stale Claim Management
      # ------------------------------------------------------------------

      # Returns atoms with stale claims (in_progress beyond timeout threshold).
      #
      # A claim is considered stale when:
      # - status is 'in_progress'
      # - updated_at is before the given threshold
      #
      # Use this for querying without modifying state.
      #
      # @param updated_before [Time] claims with updated_at before this are stale
      # @return [Array<Hash>] atoms matching stale criteria, with symbolized keys
      def stale_claims(updated_before:)
        find_stale_claims_in_worktree(updated_before: updated_before)
      end

      # Releases stale claims, returning atoms to 'open' status.
      #
      # For each stale claim found:
      # 1. Sets status to 'open'
      # 2. Clears the assignee
      # 3. Commits with message identifying the released claim
      #
      # @param updated_before [Time] claims with updated_at before this are released
      # @return [Array<String>] IDs of atoms whose claims were released
      def release_stale_claims(updated_before:)
        stale = find_stale_claims_in_worktree(updated_before: updated_before)
        return [] if stale.empty?

        released_ids = stale.map { |atom| atom[:id] }
        release_atoms_in_worktree(released_ids)

        message = build_release_commit_message(released_ids, stale)
        commit_ledger_changes(message: message)

        released_ids
      end

      # Updates an atom's timestamp without changing other fields (heartbeat).
      #
      # Long-running agents call this periodically to prevent claims from being
      # auto-released as stale. Recommended interval: claim_timeout_hours / 2.
      #
      # Any agent can heartbeat any in_progress atom—this supports cooperative
      # scenarios where agents keep each other's claims alive.
      #
      # Uses optimistic locking with retry like claim_and_push: on push conflict,
      # retries from pull with exponential backoff.
      #
      # @param atom_id [String] the atom to heartbeat
      # @return [ClaimResult] success with claimed_by and retries, or failure with error
      def heartbeat(atom_id:)
        if atom_id.nil? || atom_id.to_s.strip.empty?
          return ClaimResult.new(success: false, error: 'atom_id cannot be nil or empty')
        end

        retries = 0

        loop do
          result = attempt_heartbeat(atom_id)
          return result.with(retries: retries) if result.success || !retriable_heartbeat_error?(result)

          retries += 1
          if retries >= max_retries
            return ClaimResult.new(success: false, error: 'Max retries exceeded', retries: retries)
          end

          sleep_with_backoff(retries)
        end
      end

      private

      attr_reader :clock

      # Sleeps with exponential backoff and jitter.
      #
      # Formula: delay = min(base * 2^(attempt-1), max) ± jitter
      # Example delays for attempts 1-5: ~100ms, ~200ms, ~400ms, ~800ms, ~1600ms
      #
      # Jitter (±20%) prevents thundering herd when multiple agents retry simultaneously.
      def sleep_with_backoff(attempt)
        base_delay = [BASE_BACKOFF_MS * (2**(attempt - 1)), MAX_BACKOFF_MS].min
        jitter = base_delay * JITTER_FACTOR * rand(-1.0..1.0)
        sleep((base_delay + jitter) / 1000.0)
      end

      # ------------------------------------------------------------------
      # Branch Management
      # ------------------------------------------------------------------

      # Creates the ledger branch if it doesn't exist locally or remotely.
      # @return [Boolean] true if branch was created, false if it already existed
      def ensure_branch!
        return false if local_branch_exists? || remote_branch_exists?

        create_orphan_branch_in_main_repo
        true
      end

      # Creates an orphan branch (no parent commits) for isolated ledger history.
      #
      # Orphan branches share no history with main, keeping the ledger's
      # fast-changing state separate from the project's commit history.
      def create_orphan_branch_in_main_repo
        original_branch = git_adapter.current_branch
        git_adapter.create_orphan_branch(branch, initial_message: 'Initialize ledger branch')
        git_adapter.push_branch(remote: remote, branch: branch, set_upstream: true)
        git_adapter.checkout(original_branch)
      rescue GitError, BranchError => e
        git_adapter.checkout(original_branch) rescue nil # rubocop:disable Style/RescueModifier
        raise LedgerSyncerError, "Failed to create ledger branch: #{e.message}"
      end

      def local_branch_exists? = git_adapter.branch_exists?(branch)
      def remote_branch_exists? = git_adapter.branch_exists?(branch, remote: remote)

      # ------------------------------------------------------------------
      # Ledger Directory Helpers
      # ------------------------------------------------------------------

      # Path to .eluent/ in the sync worktree
      def worktree_ledger_dir = File.join(worktree_path, LEDGER_DIR)

      # Path to .eluent/ in the main working directory
      def main_ledger_dir = File.join(git_adapter.repo_path, LEDGER_DIR)

      def ledger_dir_empty?
        dir = worktree_ledger_dir
        !Dir.exist?(dir) || Dir.empty?(dir)
      end

      # Recursively copies all files from src to dest, preserving structure.
      #
      # Handles dotfiles but excludes symlinks (security: prevents following
      # links outside the directory) and directory self-references (. and ..).
      def sync_directory(src, dest)
        Dir.glob(File.join(src, '**', '*'), File::FNM_DOTMATCH).each do |src_path|
          next if %w[. ..].include?(File.basename(src_path))
          next if File.symlink?(src_path)

          relative = src_path.delete_prefix("#{src}/")
          dest_path = File.join(dest, relative)

          if File.directory?(src_path)
            FileUtils.mkdir_p(dest_path)
          else
            FileUtils.mkdir_p(File.dirname(dest_path))
            FileUtils.cp(src_path, dest_path)
          end
        end
      end

      # ------------------------------------------------------------------
      # Git Operations in Worktree
      # ------------------------------------------------------------------

      def fetch_ledger_branch
        git_adapter.fetch_branch(remote: remote, branch: branch)
      rescue BranchError => e
        raise LedgerSyncerError, "Failed to fetch ledger: #{e.message}"
      end

      # Hard reset to remote - we trust remote as authoritative since the
      # ledger uses optimistic locking (retry on push conflict).
      def merge_or_reset_ledger
        git_adapter.run_git_in_worktree(worktree_path, 'reset', '--hard', "#{remote}/#{branch}")
      end

      # Stages and commits all changes in the worktree. No-op if nothing changed.
      def commit_ledger_changes(message: nil)
        message ||= "Update ledger at #{clock.now.utc.iso8601}"
        git_adapter.run_git_in_worktree(worktree_path, 'add', '-A')

        status = git_adapter.run_git_in_worktree(worktree_path, 'status', '--porcelain')
        return if status.strip.empty?

        git_adapter.run_git_in_worktree(worktree_path, 'commit', '-m', message)
      rescue GitError => e
        return if e.message.include?('nothing to commit')

        raise
      end

      def cleanup_state_files
        [global_paths.ledger_sync_state_file, global_paths.ledger_lock_file].each do |file|
          FileUtils.rm_f(file)
        end
      end

      # ------------------------------------------------------------------
      # Heartbeat Helpers
      # ------------------------------------------------------------------

      # Single attempt at heartbeat without retry logic.
      def attempt_heartbeat(atom_id)
        pull_result = pull_ledger
        return ClaimResult.new(success: false, error: pull_result.error) unless pull_result.success

        atom = find_atom_in_worktree(atom_id)
        return ClaimResult.new(success: false, error: "Atom not found: #{atom_id}") unless atom

        unless atom[:status] == 'in_progress'
          return ClaimResult.new(success: false, error: "Cannot heartbeat atom in #{atom[:status]} state")
        end

        touch_atom_timestamp(atom_id)
        commit_ledger_changes(message: "Heartbeat for #{atom_id}")

        push_result = push_ledger
        return ClaimResult.new(success: false, error: push_result.error) unless push_result.success

        ClaimResult.new(success: true, claimed_by: atom[:assignee])
      end

      # Determines if a heartbeat error is worth retrying.
      #
      # Push failures are retriable (likely conflict with another agent).
      # Other failures (atom not found, wrong state) are not.
      def retriable_heartbeat_error?(result)
        return false if result.success

        error = result.error.to_s
        error.start_with?('Push failed')
      end

      # ------------------------------------------------------------------
      # Stale Claim Helpers
      # ------------------------------------------------------------------

      # Normalizes claim_timeout_hours to nil (disabled) or a positive float.
      def normalize_claim_timeout(value)
        return nil if value.nil?

        hours = value.to_f
        hours.positive? ? hours : nil
      end

      # Scans the ledger data file for claims that are stale.
      #
      # @param updated_before [Time] claims with updated_at before this are stale
      # @return [Array<Hash>] stale atoms with symbolized keys
      def find_stale_claims_in_worktree(updated_before:)
        data_file = File.join(worktree_ledger_dir, 'data.jsonl')
        return [] unless File.exist?(data_file)

        stale = []
        File.foreach(data_file) do |line|
          record = JSON.parse(line, symbolize_names: true)
          next unless stale_claim?(record, updated_before)

          stale << record
        rescue JSON::ParserError
          next
        end
        stale
      end

      # Determines if an atom record represents a stale claim.
      def stale_claim?(record, updated_before)
        return false unless record[:_type] == 'atom'
        return false unless record[:status] == 'in_progress'

        updated_at = parse_timestamp(record[:updated_at])
        return false unless updated_at

        updated_at < updated_before
      end

      # Parses an ISO8601 timestamp string into a Time object.
      #
      # @param timestamp [String, nil] ISO8601 formatted timestamp
      # @return [Time, nil] parsed time or nil if invalid/missing
      def parse_timestamp(timestamp)
        return nil if timestamp.nil? || timestamp.to_s.strip.empty?

        Time.parse(timestamp)
      rescue ArgumentError
        nil
      end

      # Builds a descriptive commit message for stale claim releases.
      #
      # For single releases, includes the previous assignee for auditability.
      # For multiple releases, lists IDs up to a reasonable length, then summarizes.
      def build_release_commit_message(released_ids, stale_atoms)
        case released_ids.size
        when 1
          atom = stale_atoms.first
          "Auto-release stale claim on #{atom[:id]} (was: #{atom[:assignee]})"
        when 2..5
          "Auto-release #{released_ids.size} stale claims: #{released_ids.join(', ')}"
        else
          preview = released_ids.first(3).join(', ')
          "Auto-release #{released_ids.size} stale claims: #{preview}, ..."
        end
      end

      # Calculates the stale threshold time based on claim_timeout_hours.
      #
      # @return [Time, nil] threshold time, or nil if auto-release is disabled
      def stale_threshold_time
        return nil unless claim_timeout_hours

        clock.now - (claim_timeout_hours * SECONDS_PER_HOUR)
      end

      # Releases stale claims if claim_timeout_hours is configured.
      #
      # Called automatically during pull_ledger. Released atoms are logged
      # for auditability. Pushes changes to remote to ensure other agents
      # see the released claims.
      #
      # Push failures are logged but don't fail the pull operation—the local
      # release still helps this agent, and the next pull will retry.
      def auto_release_stale_claims
        threshold = stale_threshold_time
        return unless threshold

        released = release_stale_claims(updated_before: threshold)
        return if released.empty?

        warn "el: auto-released #{released.size} stale claim(s): #{released.join(', ')}"

        # Best-effort push; failure is logged but doesn't fail the pull
        push_result = push_ledger
        warn "el: failed to push auto-released claims: #{push_result.error}" unless push_result.success
      end
    end
    # rubocop:enable Metrics/ClassLength

    # Raised for ledger sync operations that fail in recoverable ways.
    class LedgerSyncerError < Error; end
  end
end
