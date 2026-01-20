# frozen_string_literal: true

module Eluent
  module Agents
    # Standard agent work loop
    # Queries ready work, claims atoms, executes via executor, handles results
    class ExecutionLoop
      # @param repository [Storage::JsonlRepository] Repository to work with
      # @param executor [AgentExecutor] Executor for running agent on atoms
      # @param git_adapter [Sync::GitAdapter, nil] Optional git adapter for syncing
      # @param configuration [Configuration] Agent configuration
      def initialize(repository:, executor:, configuration:, git_adapter: nil)
        @repository = repository
        @executor = executor
        @git_adapter = git_adapter
        @configuration = configuration
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
        @running = true
        @processed_count = 0
        @error_count = 0
        results = []

        iteration = 0
        while @running && (max_iterations.nil? || iteration < max_iterations)
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
            @processed_count += 1
          else
            @error_count += 1
          end

          on_iteration&.call(iteration, result)
          iteration += 1
        end

        LoopResult.new(
          iterations: iteration,
          processed: @processed_count,
          errors: @error_count,
          results: results
        )
      ensure
        @running = false
      end

      # Stop the running loop
      def stop!
        @running = false
      end

      # Check if loop is running
      def running?
        @running
      end

      private

      attr_reader :repository, :executor, :git_adapter, :configuration

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
        claimed = claim_atom(atom)
        return ExecutionResult.failure(error: 'Failed to claim atom', atom: atom) unless claimed

        sync_before_work if git_adapter

        result = executor.execute(atom)

        handle_result(atom, result)
        sync_after_work if git_adapter && result.success

        result
      rescue StandardError => e
        release_claim(atom)
        ExecutionResult.failure(error: e.message, atom: atom)
      end

      # Claim an atom for processing by this agent
      # NOTE: This has a TOCTOU race condition between checking status and updating.
      # Multiple agents could simultaneously claim the same atom. For multi-agent
      # deployments, the repository should implement optimistic locking (version field)
      # or atomic compare-and-swap semantics. Single-agent usage is safe.
      def claim_atom(atom)
        return false if atom.status == Models::Status[:in_progress] && atom.assignee != configuration.agent_id

        atom.status = Models::Status[:in_progress]
        atom.assignee = configuration.agent_id
        repository.update_atom(atom)
        true
      rescue StandardError
        false
      end

      def release_claim(atom)
        current = repository.find_atom(atom.id)
        return unless current&.assignee == configuration.agent_id

        current.status = Models::Status[:open]
        current.assignee = nil
        repository.update_atom(current)
      rescue StandardError => e
        # Best effort release - failure is non-critical but worth noting
        # The atom may remain claimed until manual intervention or timeout
        warn "[ExecutionLoop] Failed to release claim on #{atom.id}: #{e.message}" if $DEBUG
      end

      def handle_result(atom, result)
        return unless result.success

        # Add comment about completion if item was closed
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

      def sync_after_work
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
