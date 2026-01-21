# frozen_string_literal: true

module Eluent
  module Agents
    # Outcome of an atom claim attempt.
    #
    # @!attribute success [Boolean] whether the claim succeeded
    # @!attribute reason [String, nil] failure reason if unsuccessful
    # @!attribute local_only [Boolean] true if claim exists only in local repository (not synced to remote)
    # @!attribute fallback [Boolean] true if remote sync was attempted but failed, triggering local fallback
    # @!attribute error [String, nil] error message when fallback occurred
    ClaimOutcome = Data.define(:success, :reason, :local_only, :fallback, :error) do
      def initialize(success:, reason: nil, local_only: false, fallback: false, error: nil)
        super
      end

      def success? = success
      def failed? = !success
      def local_only? = local_only
      def fallback? = fallback
    end

    # Standard agent work loop
    # Queries ready work, claims atoms, executes via executor, handles results
    class ExecutionLoop
      # @param repository [Storage::JsonlRepository] Repository to work with
      # @param executor [AgentExecutor] Executor for running agent on atoms
      # @param git_adapter [Sync::GitAdapter, nil] Optional git adapter for syncing
      # @param ledger_syncer [Sync::LedgerSyncer, nil] Optional ledger syncer for atomic claims
      # @param ledger_sync_state [Sync::LedgerSyncState, nil] State tracker for offline claims
      # @param configuration [Configuration] Agent configuration
      # @param sync_config [Hash] Sync configuration (offline_mode, etc.)
      # @param clock [#now] Time source for timestamps (defaults to Time, injectable for testing)
      def initialize(repository:, executor:, configuration:, git_adapter: nil,
                     ledger_syncer: nil, ledger_sync_state: nil, sync_config: {}, clock: Time)
        @repository = repository
        @executor = executor
        @git_adapter = git_adapter
        @ledger_syncer = ledger_syncer
        @ledger_sync_state = ledger_sync_state
        @configuration = configuration
        @sync_config = sync_config
        @clock = clock
        @running = false
        @processed_count = 0
        @error_count = 0
      end

      # Run the agent loop
      # @param max_iterations [Integer, nil] Maximum iterations (nil for unlimited)
      # @param assignee_filter [String, nil] Only process items assigned to this ID
      # @param type_filter [Symbol, nil] Only process items of this type
      # @param on_iteration [Proc, nil] Callback after each iteration
      # @return [LoopResult] Summary of the run
      def run(max_iterations: nil, assignee_filter: nil, type_filter: nil, on_iteration: nil)
        self.running = true
        self.processed_count = 0
        self.error_count = 0
        results = []

        iteration = 0
        while running && (max_iterations.nil? || iteration < max_iterations)
          atom = begin
            find_ready_work(assignee_filter: assignee_filter, type_filter: type_filter)
          rescue StandardError
            # Repository error during work discovery - continue loop to retry
            nil
          end
          break unless atom

          result = process_atom(atom)
          results << result

          if result.success
            self.processed_count += 1
          else
            self.error_count += 1
          end

          on_iteration&.call(iteration, result)
          iteration += 1
        end

        LoopResult.new(
          iterations: iteration,
          processed: processed_count,
          errors: error_count,
          results: results
        )
      ensure
        self.running = false
      end

      # Stop the running loop
      def stop!
        self.running = false
      end

      # Check if loop is running
      def running?
        running
      end

      private

      attr_reader :repository, :executor, :git_adapter, :ledger_syncer, :ledger_sync_state,
                  :configuration, :sync_config, :clock
      attr_accessor :running, :processed_count, :error_count

      def find_ready_work(assignee_filter:, type_filter:)
        calculator = build_readiness_calculator

        items = calculator.ready_items(
          sort: :priority,
          type: type_filter,
          assignee: assignee_filter,
          include_abstract: false
        )

        items.first
      end

      def build_readiness_calculator
        blocking_resolver = Graph::BlockingResolver.new(repository.indexer)
        Lifecycle::ReadinessCalculator.new(
          indexer: repository.indexer,
          blocking_resolver: blocking_resolver
        )
      end

      def process_atom(atom)
        claim_outcome = claim_atom(atom)
        unless claim_outcome.success?
          return ExecutionResult.failure(error: claim_outcome.reason || 'Failed to claim atom', atom: atom)
        end

        sync_before_work if git_adapter

        result = executor.execute(atom)

        handle_result(atom, result)
        sync_after_work(result.success)

        result
      rescue StandardError => e
        release_claim_on_failure(atom)
        ExecutionResult.failure(error: e.message, atom: atom)
      end

      # Claims an atom for processing by this agent.
      #
      # When a ledger syncer is available, performs an atomic remote claim with
      # conflict detection and retry. Falls back to local-only claiming when:
      # - No ledger syncer is configured
      # - Remote is unavailable and offline_mode is 'local'
      #
      # @param atom [Models::Atom] The atom to claim
      # @return [ClaimOutcome] Result indicating success/failure and offline status
      def claim_atom(atom)
        return claim_with_ledger_sync(atom) if ledger_syncer_available?

        claim_locally(atom)
      rescue Sync::LedgerSyncerError, Sync::WorktreeError, Sync::BranchError, Sync::GitError => e
        handle_ledger_sync_failure(atom, e)
      end

      # Safely checks if ledger syncer is available without raising.
      def ledger_syncer_available?
        ledger_syncer&.available?
      rescue Sync::WorktreeError, Sync::BranchError, Sync::GitError
        false
      end

      # Releases a claim on failure, allowing other agents to pick up the work.
      #
      # Attempts remote release if ledger syncer is available. Always releases
      # locally regardless of remote outcome. Remote failures are logged but
      # don't propagate since the claim will eventually timeout or be manually released.
      #
      # @param atom [Models::Atom] The atom to release
      def release_claim_on_failure(atom)
        ledger_syncer.release_claim(atom_id: atom.id) if ledger_syncer_available?
      rescue Sync::LedgerSyncerError, Sync::WorktreeError, Sync::BranchError, Sync::GitError => e
        warn "[ExecutionLoop] Ledger release failed for #{atom.id}: #{e.message}" if $DEBUG
      ensure
        release_claim_locally(atom)
      end

      # Performs atomic claim via ledger syncer with retry on conflict.
      def claim_with_ledger_sync(atom)
        result = ledger_syncer.claim_and_push(atom_id: atom.id, agent_id: configuration.agent_id)

        if result.success
          reload_repository_after_claim
          ClaimOutcome.new(success: true, local_only: result.offline_claim)
        else
          ClaimOutcome.new(success: false, reason: result.error, local_only: result.offline_claim)
        end
      end

      # Reloads repository to pick up changes from other agents after a successful remote claim.
      # Failures are logged but don't fail the claim - stale local state is better than losing
      # a successfully committed remote claim.
      def reload_repository_after_claim
        repository.load!
      rescue StandardError => e
        warn "[ExecutionLoop] Repository reload failed after claim: #{e.message}" if $DEBUG
      end

      # Claims an atom using only the local repository, without remote synchronization.
      def claim_locally(atom)
        if atom.status == Models::Status[:in_progress] && atom.assignee != configuration.agent_id
          owner = atom.assignee.to_s.empty? ? 'another agent' : atom.assignee
          return ClaimOutcome.new(success: false, reason: "Already claimed by #{owner}")
        end

        atom.status = Models::Status[:in_progress]
        atom.assignee = configuration.agent_id
        repository.update_atom(atom)

        ClaimOutcome.new(success: true, local_only: true)
      rescue StandardError => e
        ClaimOutcome.new(success: false, reason: e.message)
      end

      # Handles ledger sync failures based on configured offline_mode.
      #
      # When offline_mode is 'local' (default), falls back to local claiming
      # and records the claim for later reconciliation. When 'fail', returns
      # a failure outcome immediately without fallback.
      def handle_ledger_sync_failure(atom, error)
        if offline_mode == 'local'
          outcome = claim_locally(atom)
          return outcome unless outcome.success?

          record_offline_claim(atom)
          ClaimOutcome.new(success: true, local_only: true, fallback: true, error: error.message)
        else
          ClaimOutcome.new(success: false, reason: error.message)
        end
      end

      def offline_mode
        sync_config['offline_mode'] || 'local'
      end

      def record_offline_claim(atom)
        return unless ledger_sync_state

        ledger_sync_state.load if ledger_sync_state.exists?
        ledger_sync_state.record_offline_claim(
          atom_id: atom.id,
          agent_id: configuration.agent_id,
          claimed_at: clock.now
        )
        ledger_sync_state.save
      rescue StandardError => e
        warn "[ExecutionLoop] Failed to record offline claim for #{atom.id}: #{e.message}" if $DEBUG
      end

      def release_claim_locally(atom)
        current = repository.find_atom(atom.id)
        return unless current&.assignee == configuration.agent_id

        current.status = Models::Status[:open]
        current.assignee = nil
        repository.update_atom(current)
      rescue StandardError => e
        warn "[ExecutionLoop] Failed to release claim on #{atom.id}: #{e.message}" if $DEBUG
      end

      def handle_result(atom, result)
        return unless result.success

        # Record work summary as audit trail for human review
        if result.close_reason
          repository.create_comment(
            parent_id: atom.id,
            author: configuration.agent_id,
            content: "Agent completed work: #{result.close_reason}"
          )
        end

        # Create any follow-up items
        Array(result.follow_ups).each do |follow_up|
          create_follow_up(atom, follow_up)
        end
      end

      def create_follow_up(_parent_atom, follow_up)
        attrs = case follow_up
                when String
                  { title: follow_up }
                when Hash
                  follow_up
                else
                  return
                end

        repository.create_atom(**attrs)
      end

      def sync_before_work
        git_adapter.pull
      rescue Sync::GitError => e
        # Continue even if sync fails - agent can work on stale data
        warn "[ExecutionLoop] Pre-work sync failed: #{e.message}" if $DEBUG
      end

      # Syncs work results to remote repositories.
      #
      # On successful work completion, pushes ledger changes (atom status) to the
      # fast-sync branch, then copies those changes to the working tree so they're
      # included in the code commit.
      #
      # @param work_succeeded [Boolean] Whether the work was successful
      def sync_after_work(work_succeeded)
        sync_ledger_after_work if ledger_syncer_available? && work_succeeded
        sync_git_after_work if git_adapter && work_succeeded
      end

      def sync_ledger_after_work
        result = ledger_syncer.push_ledger
        unless result.success
          warn "[ExecutionLoop] Ledger push failed: #{result.error}" if $DEBUG
          return
        end

        sync_result = ledger_syncer.sync_to_main
        warn "[ExecutionLoop] Ledger sync to main failed: #{sync_result.error}" if $DEBUG && !sync_result.success
      rescue Sync::LedgerSyncerError, Sync::WorktreeError, Sync::BranchError, Sync::GitError => e
        # Log but don't fail work completion; ledger will sync later
        warn "[ExecutionLoop] Ledger sync failed: #{e.message}" if $DEBUG
      end

      def sync_git_after_work
        git_adapter.add(paths: repository.paths.data_file)
        git_adapter.commit(message: "[eluent-agent] #{configuration.agent_id} completed work")
        git_adapter.push
      rescue Sync::GitError => e
        # Work was completed but sync failed - changes remain local
        warn "[ExecutionLoop] Post-work sync failed: #{e.message}" if $DEBUG
      end
    end

    # Result of running the execution loop
    LoopResult = Data.define(:iterations, :processed, :errors, :results) do
      def success?
        errors.zero?
      end

      def summary
        "Completed #{iterations} iterations: #{processed} processed, #{errors} errors"
      end
    end
  end
end
