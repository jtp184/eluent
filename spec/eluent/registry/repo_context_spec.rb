# frozen_string_literal: true

require 'tempfile'
require 'fileutils'

RSpec.describe Eluent::Registry::RepoContext do
  # Tests that don't need atom operations use FakeFS
  describe 'FakeFS tests', :filesystem do
    let(:registry_path) { '/home/user/.eluent/repos.jsonl' }
    let(:repo_registry) { Eluent::Registry::RepoRegistry.new(registry_path: registry_path) }
    let(:context) { described_class.new(repo_registry: repo_registry) }

    before do
      FakeFS.activate!
      FakeFS::FileSystem.clear
      FileUtils.mkdir_p(File.dirname(registry_path))
    end

    after { FakeFS.deactivate! }

    describe '#get_repository' do
      it 'loads and returns the repository when it exists' do
        setup_eluent_directory('/projects/test')
        repo = context.get_repository('/projects/test')
        expect(repo).to be_a(Eluent::Storage::JsonlRepository)
      end

      it 'caches the repository' do
        setup_eluent_directory('/projects/test')
        repo1 = context.get_repository('/projects/test')
        repo2 = context.get_repository('/projects/test')
        expect(repo1).to be(repo2)
      end

      it 'raises RepositoryNotFoundError when path is nil' do
        expect { context.get_repository(nil) }
          .to raise_error(Eluent::Registry::RepoContext::RepositoryNotFoundError)
      end

      it 'raises RepositoryNotFoundError when repository does not exist' do
        expect { context.get_repository('/nonexistent') }
          .to raise_error(Eluent::Registry::RepoContext::RepositoryNotFoundError, /No .eluent directory/)
      end
    end

    describe '#get_repository_by_name' do
      before do
        setup_eluent_directory('/projects/my-project')
        repo_registry.register(name: 'my-project', path: '/projects/my-project')
      end

      it 'returns repository for registered name' do
        repo = context.get_repository_by_name('my-project')
        expect(repo).to be_a(Eluent::Storage::JsonlRepository)
      end

      it 'raises RepositoryNotFoundError for unregistered name' do
        expect { context.get_repository_by_name('unknown') }
          .to raise_error(Eluent::Registry::RepoContext::RepositoryNotFoundError)
      end
    end

    describe '#registered?' do
      before { repo_registry.register(name: 'test', path: '/test') }

      it 'returns true for registered name' do
        expect(context.registered?('test')).to be true
      end

      it 'returns false for unregistered name' do
        expect(context.registered?('unknown')).to be false
      end
    end

    describe '#registered_repositories' do
      before do
        repo_registry.register(name: 'project-a', path: '/projects/a')
        repo_registry.register(name: 'project-b', path: '/projects/b')
      end

      it 'returns all registered repositories' do
        repos = context.registered_repositories
        expect(repos.size).to eq(2)
        expect(repos.map(&:name)).to contain_exactly('project-a', 'project-b')
      end
    end

    describe '#clear_cache' do
      before { setup_eluent_directory('/projects/test') }

      it 'clears the repository cache' do
        repo1 = context.get_repository('/projects/test')
        context.clear_cache
        repo2 = context.get_repository('/projects/test')
        expect(repo1).not_to be(repo2)
      end
    end

    describe '#current_repository' do
      it 'finds the repository root when in a repository directory' do
        setup_eluent_directory('/projects/my-project')
        FileUtils.mkdir_p('/projects/my-project/src/lib')
        repo = context.current_repository(from_path: '/projects/my-project/src/lib')
        expect(repo).to be_a(Eluent::Storage::JsonlRepository)
      end

      it 'returns nil when not in a repository' do
        FileUtils.mkdir_p('/some/other/path')
        expect(context.current_repository(from_path: '/some/other/path')).to be_nil
      end
    end

    describe 'thread safety' do
      before { setup_eluent_directory('/projects/test') }

      it 'handles concurrent access' do
        threads = 5.times.map do
          Thread.new { context.get_repository('/projects/test') }
        end
        results = threads.map(&:value)
        expect(results.uniq.size).to eq(1)
      end
    end
  end

  # Tests that need atom operations use real temp directories
  describe 'real filesystem tests' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:registry_path) { File.join(temp_dir, '.eluent', 'repos.jsonl') }
    let(:repo_registry) { Eluent::Registry::RepoRegistry.new(registry_path: registry_path) }
    let(:context) { described_class.new(repo_registry: repo_registry) }

    after { FileUtils.rm_rf(temp_dir) }

    def setup_repo(name)
      path = File.join(temp_dir, name)
      repo = Eluent::Storage::JsonlRepository.new(path)
      repo.init(repo_name: name)
      repo_registry.register(name: name, path: path)
      repo
    end

    describe '#find_atom_by_full_id' do
      let(:atom_id) { 'myrepo-01ARZ3NDEKTSV4RRFFQ69G5FAV' }

      before { setup_repo('myrepo') }

      it 'returns the atom when it exists' do
        repo = context.get_repository_by_name('myrepo')
        repo.create_atom(id: atom_id, title: 'Test Atom')

        result = context.find_atom_by_full_id(atom_id)
        expect(result[:atom]).not_to be_nil
        expect(result[:atom].title).to eq('Test Atom')
      end

      it 'returns repo_not_registered error when repo is not registered' do
        result = context.find_atom_by_full_id('unknown-01ARZ3NDEKTSV4RRFFQ69G5FAV')
        expect(result[:error]).to eq(:repo_not_registered)
        expect(result[:name]).to eq('unknown')
      end

      it 'returns not_found error when atom does not exist' do
        result = context.find_atom_by_full_id(atom_id)
        expect(result[:error]).to eq(:not_found)
        expect(result[:id]).to eq(atom_id)
      end

      it 'returns invalid_id error with invalid ID format' do
        result = context.find_atom_by_full_id('invalid')
        expect(result[:error]).to eq(:invalid_id)
      end
    end

    describe '#resolve_id' do
      before { setup_repo('testrepo') }

      it 'resolves full valid atom ID across repositories' do
        atom_id = 'testrepo-01ARZ3NDEKTSV4RRFFQ69G5FAV'
        repo = context.get_repository_by_name('testrepo')
        repo.create_atom(id: atom_id, title: 'Test Atom')

        result = context.resolve_id(atom_id)
        expect(result[:atom]).not_to be_nil
        expect(result[:atom].id).to eq(atom_id)
      end

      it 'requires repo_path for short prefix lookups' do
        expect { context.resolve_id('ABCD') }
          .to raise_error(Eluent::Registry::RepoContext::RepositoryNotFoundError, /repo_path required/)
      end

      it 'resolves short prefix within specified repository' do
        repo = context.get_repository_by_name('testrepo')
        atom = repo.create_atom(title: 'Test Atom')
        short_id = Eluent::Registry::IdGenerator.extract_randomness(atom.id)[0, 6]

        result = context.resolve_id(short_id, repo_path: repo_registry.path_for('testrepo'))
        expect(result[:atom]).not_to be_nil
        expect(result[:atom].id).to eq(atom.id)
      end
    end
  end

  describe Eluent::Registry::RepoContext::RepositoryNotFoundError do
    it 'stores the identifier' do
      error = described_class.new('test-repo')
      expect(error.identifier).to eq('test-repo')
      expect(error.message).to include('test-repo')
    end
  end
end
