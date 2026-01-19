# frozen_string_literal: true

module Eluent
  module Registry
    # Repository context management for cross-repo operations
    # Single responsibility: resolve and cache repository instances
    class RepoContext
      # Error raised when a repository cannot be found
      class RepositoryNotFoundError < Error
        attr_reader :identifier

        def initialize(identifier)
          @identifier = identifier
          super("Repository not found: #{identifier}")
        end
      end

      def initialize(repo_registry: RepoRegistry.new)
        @repo_registry = repo_registry
        @repo_cache = {}
        @mutex = Mutex.new
      end

      # Get a repository by path, loading and caching it if necessary.
      #
      # @param repo_path [String] Path to the repository
      # @return [Storage::JsonlRepository] The loaded repository
      # @raise [RepositoryNotFoundError] if path is nil or repository doesn't exist
      def get_repository(repo_path)
        raise RepositoryNotFoundError, repo_path if repo_path.nil?

        mutex.synchronize do
          repo_cache[repo_path] ||= load_repository(repo_path)
        end
      end

      # Get a repository by registered name.
      #
      # @param name [String] The registered repository name
      # @return [Storage::JsonlRepository] The loaded repository
      # @raise [RepositoryNotFoundError] if name is not registered
      def get_repository_by_name(name)
        path = repo_registry.path_for(name)
        raise RepositoryNotFoundError, name unless path

        get_repository(path)
      end

      # Find an atom across repositories using a full ID.
      # Parses the repo name from the ID and resolves to the correct repository.
      #
      # @param full_id [String] Full atom ID (e.g., "eluent-01ARZ3NDEKTSV4RRFFQ69G5FAV")
      # @return [Hash] Result with :atom key on success, or :error key on failure
      def find_atom_by_full_id(full_id)
        repo_name = IdGenerator.extract_repo_name(full_id)
        return { error: :invalid_id, message: "Cannot parse repo name from: #{full_id}" } unless repo_name

        path = repo_registry.path_for(repo_name)
        return { error: :repo_not_registered, name: repo_name } unless path

        repo = get_repository(path)
        atom = repo.find_atom(full_id)

        atom ? { atom: atom } : { error: :not_found, id: full_id }
      rescue RepositoryNotFoundError => e
        { error: :repo_not_found, message: e.message }
      end

      # Resolve an ID that may be a short prefix or full ID.
      # For short prefixes, searches only in the specified repository.
      # For full IDs, can resolve across repositories.
      #
      # @param input [String] Short prefix or full ID
      # @param repo_path [String, nil] Path to repository for prefix resolution
      # @return [Hash] Result with :atom key on success, or :error key on failure
      def resolve_id(input, repo_path: nil)
        return find_atom_by_full_id(input) if IdGenerator.valid_atom_id?(input)

        raise RepositoryNotFoundError, 'repo_path required for prefix resolution' unless repo_path

        repo = get_repository(repo_path)
        repo.id_resolver.resolve(input)
      end

      # Check if a repository is registered by name.
      #
      # @param name [String] Repository name
      # @return [Boolean]
      def registered?(name)
        repo_registry.exists?(name)
      end

      # List all registered repositories.
      #
      # @return [Array<RepoRegistry::Entry>]
      def registered_repositories
        repo_registry.all
      end

      # Clear the repository cache.
      # Useful for testing or when repository state has changed externally.
      def clear_cache
        mutex.synchronize do
          repo_cache.clear
        end
      end

      # Get the current repository based on working directory.
      # Walks up the directory tree looking for a .eluent directory.
      #
      # @param from_path [String] Starting path (defaults to current directory)
      # @return [Storage::JsonlRepository, nil] The repository, or nil if not found
      def current_repository(from_path: Dir.pwd)
        path = find_eluent_root(from_path)
        path ? get_repository(path) : nil
      end

      private

      attr_reader :repo_registry, :repo_cache, :mutex

      def load_repository(repo_path)
        expanded = File.expand_path(repo_path)
        eluent_dir = File.join(expanded, '.eluent')

        raise RepositoryNotFoundError, "No .eluent directory at: #{expanded}" unless File.directory?(eluent_dir)

        Storage::JsonlRepository.new(expanded).tap(&:load!)
      end

      def find_eluent_root(from_path)
        path = File.expand_path(from_path)

        loop do
          return path if File.directory?(File.join(path, '.eluent'))

          parent = File.dirname(path)
          return nil if parent == path # Reached filesystem root

          path = parent
        end
      end
    end
  end
end
