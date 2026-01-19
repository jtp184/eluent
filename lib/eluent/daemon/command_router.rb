# frozen_string_literal: true

module Eluent
  module Daemon
    # Routes daemon requests to appropriate handlers
    # Single responsibility: dispatch commands to handlers
    class CommandRouter
      COMMANDS = %w[ping list show create update close reopen ready sync comment dep].freeze

      def initialize(repo_cache: {})
        @repo_cache = repo_cache
        @mutex = Mutex.new
      end

      def route(request)
        id = request[:id]
        cmd = request[:cmd]
        args = request[:args] || {}

        unless COMMANDS.include?(cmd)
          return Protocol.build_error(id: id, code: 'UNKNOWN_COMMAND', message: "Unknown command: #{cmd}")
        end

        handler = "handle_#{cmd}"
        send(handler, args, id)
      rescue Storage::RepositoryNotFoundError => e
        Protocol.build_error(id: id, code: 'REPO_NOT_FOUND', message: e.message)
      rescue Registry::IdNotFoundError => e
        Protocol.build_error(id: id, code: 'NOT_FOUND', message: e.message)
      rescue Registry::AmbiguousIdError => e
        Protocol.build_error(id: id, code: 'AMBIGUOUS_ID', message: e.message,
                             details: { candidates: e.candidates.map(&:to_h) })
      rescue Models::ValidationError => e
        Protocol.build_error(id: id, code: 'VALIDATION_ERROR', message: e.message)
      rescue Graph::CycleDetectedError => e
        Protocol.build_error(id: id, code: 'CYCLE_DETECTED', message: e.message)
      rescue StandardError => e
        Protocol.build_error(id: id, code: 'INTERNAL_ERROR', message: e.message)
      end

      private

      attr_reader :repo_cache, :mutex

      def handle_ping(_args, id)
        Protocol.build_success(id: id, data: { pong: true, time: Time.now.utc.iso8601 })
      end

      def handle_list(args, id)
        repo = get_repository(args[:repo_path])
        atoms = repo.list_atoms(
          status: args[:status],
          issue_type: args[:issue_type],
          assignee: args[:assignee],
          labels: args[:labels],
          include_discarded: args[:include_discarded]
        )

        Protocol.build_success(id: id, data: { atoms: atoms.map(&:to_h) })
      end

      def handle_show(args, id)
        repo = get_repository(args[:repo_path])
        atom = repo.find_atom(args[:id])

        raise Registry::IdNotFoundError, args[:id] unless atom

        bonds = repo.bonds_for(atom.id)
        comments = repo.comments_for(atom.id)

        Protocol.build_success(id: id, data: {
                                 atom: atom.to_h,
                                 bonds: { outgoing: bonds[:outgoing].map(&:to_h),
                                          incoming: bonds[:incoming].map(&:to_h) },
                                 comments: comments.map(&:to_h)
                               })
      end

      def handle_create(args, id)
        repo = get_repository(args[:repo_path])
        attrs = args.except(:repo_path)
        atom = repo.create_atom(attrs)

        Protocol.build_success(id: id, data: { atom: atom.to_h })
      end

      def handle_update(args, id)
        repo = get_repository(args[:repo_path])
        atom = repo.find_atom(args[:id])

        raise Registry::IdNotFoundError, args[:id] unless atom

        # Apply updates
        %i[title description status issue_type priority assignee labels parent_id defer_until
           close_reason].each do |field|
          atom.send("#{field}=", args[field]) if args.key?(field)
        end

        atom.metadata = atom.metadata.merge(args[:metadata]) if args.key?(:metadata)

        repo.update_atom(atom)

        Protocol.build_success(id: id, data: { atom: atom.to_h })
      end

      def handle_close(args, id)
        repo = get_repository(args[:repo_path])
        atom = repo.find_atom(args[:id])

        raise Registry::IdNotFoundError, args[:id] unless atom

        atom.status = Models::Status.find(:closed)
        atom.close_reason = args[:reason] if args[:reason]
        repo.update_atom(atom)

        Protocol.build_success(id: id, data: { atom: atom.to_h })
      end

      def handle_reopen(args, id)
        repo = get_repository(args[:repo_path])
        atom = repo.find_atom(args[:id])

        raise Registry::IdNotFoundError, args[:id] unless atom

        atom.status = Models::Status.find(:open)
        atom.close_reason = nil
        repo.update_atom(atom)

        Protocol.build_success(id: id, data: { atom: atom.to_h })
      end

      def handle_ready(args, id)
        repo = get_repository(args[:repo_path])
        atom = repo.find_atom(args[:id])

        raise Registry::IdNotFoundError, args[:id] unless atom

        calculator = Lifecycle::ReadinessCalculator.new(repository: repo)
        result = calculator.calculate(atom)

        Protocol.build_success(id: id, data: {
                                 ready: result.ready?,
                                 blockers: result.blockers.map(&:to_h)
                               })
      end

      def handle_sync(args, id)
        repo = get_repository(args[:repo_path])

        git_adapter = Sync::GitAdapter.new(repo_path: repo.paths.root)
        sync_state = Sync::SyncState.new(paths: repo.paths).load

        orchestrator = Sync::PullFirstOrchestrator.new(
          repository: repo,
          git_adapter: git_adapter,
          sync_state: sync_state
        )

        result = orchestrator.sync(
          pull_only: args[:pull_only],
          push_only: args[:push_only],
          dry_run: args[:dry_run],
          force: args[:force]
        )

        Protocol.build_success(id: id, data: {
                                 status: result.status.to_s,
                                 changes: result.changes,
                                 conflicts: result.conflicts,
                                 commits: result.commits
                               })
      end

      def handle_comment(args, id)
        repo = get_repository(args[:repo_path])

        comment = repo.create_comment(
          parent_id: args[:parent_id],
          author: args[:author],
          content: args[:content]
        )

        Protocol.build_success(id: id, data: { comment: comment.to_h })
      end

      def handle_dep(args, id)
        repo = get_repository(args[:repo_path])

        if args[:remove]
          repo.remove_bond(
            source_id: args[:source_id],
            target_id: args[:target_id],
            dependency_type: args[:dependency_type] || 'blocks'
          )
          Protocol.build_success(id: id, data: { removed: true })
        else
          bond = repo.create_bond(
            source_id: args[:source_id],
            target_id: args[:target_id],
            dependency_type: args[:dependency_type] || 'blocks'
          )
          Protocol.build_success(id: id, data: { bond: bond.to_h })
        end
      end

      def get_repository(repo_path)
        raise Storage::RepositoryNotFoundError, repo_path if repo_path.nil?

        mutex.synchronize do
          repo_cache[repo_path] ||= begin
            repo = Storage::JsonlRepository.new(repo_path)
            repo.load!
            repo
          end
        end
      end
    end
  end
end
