# frozen_string_literal: true

module Eluent
  module Agents
    # Result of executing an agent on an atom
    ExecutionResult = Data.define(:success, :atom, :close_reason, :follow_ups, :error) do
      def self.success(atom:, close_reason: nil, follow_ups: [])
        new(success: true, atom: atom, close_reason: close_reason, follow_ups: follow_ups, error: nil)
      end

      def self.failure(error:, atom: nil)
        new(success: false, atom: atom, close_reason: nil, follow_ups: [], error: error)
      end
    end

    # Abstract base class for AI agent executors.
    # Provides tool implementations and common infrastructure for working with atoms.
    #
    # == Tool Execution Contract
    # Subclasses communicate with AI models and route tool calls through #execute_tool.
    # The AI signals work completion by calling the close_item tool, which returns JSON
    # containing a 'closed' key. Executors detect this via tool_result_closes_item?
    # (from JsonParsing concern) to break out of their execution loop.
    #
    # == Implementing a New Executor
    # Subclasses must implement #execute(atom, system_prompt:) which should:
    # 1. Send the system prompt and initial message to the AI API
    # 2. Loop: receive response, extract tool calls, execute tools via #execute_tool
    # 3. Continue until no tool calls remain or close_item is called
    # 4. Return an ExecutionResult (success or failure)
    #
    # == close_reason Flow
    # When the AI calls close_item with a reason, the atom's close_reason field is set.
    # After execution completes, ExecutionResult.success carries this close_reason
    # so callers (like ExecutionLoop) can log or act on the completion summary.
    class AgentExecutor
      def initialize(repository:, configuration:)
        @repository = repository
        @configuration = configuration
      end

      # Execute the agent on an atom
      # @param atom [Models::Atom] The atom to work on
      # @param system_prompt [String, nil] Custom system prompt override
      # @return [ExecutionResult] Result of execution
      def execute(atom, system_prompt: nil)
        raise NotImplementedError, 'Subclasses must implement #execute'
      end

      protected

      # Build success result, refreshing atom from repository to capture any changes
      # @param atom [Models::Atom] The original atom passed to execute
      # @return [ExecutionResult] Success or failure result
      def build_success_result(atom)
        refreshed_atom = repository.find_atom(atom.id)
        # Handle case where atom was deleted during execution
        return ExecutionResult.failure(error: 'Atom was deleted during execution', atom: atom) unless refreshed_atom

        ExecutionResult.success(atom: refreshed_atom, close_reason: refreshed_atom.close_reason)
      end

      # Route a tool call to the appropriate handler
      # @param tool_name [String] Name of the tool to call
      # @param arguments [Hash] Arguments for the tool
      # @return [Hash] Tool result
      def execute_tool(tool_name, arguments)
        return { error: 'Tool name must be a non-empty string' } unless valid_tool_name?(tool_name)
        return { error: 'Arguments must be a Hash or nil' } unless arguments.nil? || arguments.is_a?(Hash)

        method_name = "tool_#{tool_name}"

        return { error: "Unknown tool: #{tool_name}" } unless respond_to?(method_name, true)

        send(method_name, **symbolize_keys(arguments || {}))
      rescue StandardError => e
        { error: e.message }
      end

      # --- Tool Implementations ---

      def tool_list_items(status: nil, type: nil, assignee: nil, labels: nil, include_closed: false)
        atoms = repository.list_atoms(
          status: status ? Models::Status[status.to_sym] : nil,
          issue_type: type ? Models::IssueType[type.to_sym] : nil,
          assignee: assignee,
          labels: labels || []
        )

        atoms = atoms.reject(&:closed?) unless include_closed

        {
          count: atoms.size,
          items: atoms.map { |a| atom_summary(a) }
        }
      end

      def tool_show_item(id:)
        atom = repository.find_atom(id)
        return { error: "Item not found: #{id}" } unless atom

        bonds = repository.bonds_for(atom.id)
        comments = repository.comments_for(atom.id)

        {
          item: atom.to_h,
          dependencies: {
            blocks: bonds[:outgoing].select { |b| b.dependency_type == 'blocks' }.map(&:target_id),
            blocked_by: bonds[:incoming].select { |b| b.dependency_type == 'blocks' }.map(&:source_id)
          },
          comments: comments.map { |c| { author: c.author, content: c.content, created_at: c.created_at.iso8601 } }
        }
      end

      VALID_PRIORITY_RANGE = (0..4)
      ALLOWED_UPDATE_FIELDS = %i[status priority title description assignee labels].freeze

      def tool_create_item(title:, description: nil, type: 'task', priority: 2, assignee: nil, labels: nil)
        return { error: 'Title is required' } if title.nil? || title.to_s.strip.empty?
        return { error: 'Priority must be between 0 and 4' } unless VALID_PRIORITY_RANGE.cover?(priority)

        atom = repository.create_atom(
          title: title,
          description: description,
          issue_type: type.to_sym,
          priority: priority,
          assignee: assignee,
          labels: labels || []
        )

        { created: atom_summary(atom) }
      end

      def tool_update_item(id:, **updates)
        atom = repository.find_atom(id)
        return { error: "Item not found: #{id}" } unless atom

        # Validate priority if being updated
        if updates.key?(:priority) && !VALID_PRIORITY_RANGE.cover?(updates[:priority])
          return { error: 'Priority must be between 0 and 4' }
        end

        # Only process allowed fields
        updates.slice(*ALLOWED_UPDATE_FIELDS).each do |field, value|
          case field
          when :status then atom.status = Models::Status[value.to_sym]
          when :priority then atom.priority = value
          when :labels then atom.labels = value
          when :title, :description, :assignee then atom.public_send(:"#{field}=", value)
          end
        end

        repository.update_atom(atom)
        { updated: atom_summary(atom) }
      end

      def tool_close_item(id:, reason: nil)
        atom = repository.find_atom(id)
        return { error: "Item not found: #{id}" } unless atom

        atom.status = Models::Status[:closed]
        atom.close_reason = reason
        repository.update_atom(atom)

        { closed: atom_summary(atom) }
      end

      MAX_LIST_LIMIT = 50

      def tool_list_ready_items(sort: 'priority', type: nil, assignee: nil, limit: 10)
        # Enforce documented maximum limit
        effective_limit = limit.to_i.clamp(1, MAX_LIST_LIMIT)

        indexer = repository.indexer
        blocking_resolver = Graph::BlockingResolver.new(indexer)
        calculator = Lifecycle::ReadinessCalculator.new(indexer: indexer, blocking_resolver: blocking_resolver)

        items = calculator.ready_items(
          sort: sort.to_sym,
          type: type&.to_sym,
          assignee: assignee
        ).first(effective_limit)

        {
          count: items.size,
          items: items.map { |a| atom_summary(a) }
        }
      end

      def tool_add_dependency(source_id:, target_id:, dependency_type: 'blocks')
        source = repository.find_atom(source_id)
        return { error: "Source item not found: #{source_id}" } unless source

        target = repository.find_atom(target_id)
        return { error: "Target item not found: #{target_id}" } unless target

        bond = repository.create_bond(
          source_id: source.id,
          target_id: target.id,
          dependency_type: dependency_type
        )

        { created: { source: source_id, target: target_id, type: bond.dependency_type } }
      end

      def tool_add_comment(id:, content:)
        atom = repository.find_atom(id)
        return { error: "Item not found: #{id}" } unless atom

        comment = repository.create_comment(
          parent_id: atom.id,
          author: configuration.agent_id,
          content: content
        )

        { created: { id: comment.id, content: content } }
      end

      private

      attr_reader :repository, :configuration

      def atom_summary(atom)
        {
          id: atom.id,
          title: atom.title,
          status: atom.status.name,
          type: atom.issue_type.name,
          priority: atom.priority
        }
      end

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end

      def valid_tool_name?(tool_name)
        tool_name.is_a?(String) && !tool_name.strip.empty?
      end

      def default_system_prompt(atom)
        <<~PROMPT
          You are an AI agent working on task tracking items for Eluent.

          Your current task is:
          ID: #{atom.id}
          Title: #{atom.title}
          Description: #{atom.description || 'No description'}
          Status: #{atom.status.name}
          Priority: #{atom.priority}

          You have access to tools for managing work items. When your work is complete,
          use the close_item tool to mark the item as done with a summary of what was accomplished.

          If you encounter blockers or need human input, update the item status to 'blocked'
          and add a comment explaining the blocker.
        PROMPT
      end
    end
  end
end
