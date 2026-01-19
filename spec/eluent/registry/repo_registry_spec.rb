# frozen_string_literal: true

RSpec.describe Eluent::Registry::RepoRegistry, :filesystem do
  let(:registry_path) { '/home/user/.eluent/repos.jsonl' }
  let(:registry) { described_class.new(registry_path: registry_path) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    FileUtils.mkdir_p(File.dirname(registry_path))
  end

  after { FakeFS.deactivate! }

  describe '#register' do
    it 'registers a new repository' do
      entry = registry.register(name: 'my-project', path: '/projects/my-project')

      expect(entry.name).to eq('my-project')
      expect(entry.path).to eq('/projects/my-project')
    end

    it 'expands the path' do
      entry = registry.register(name: 'test', path: '/projects/../projects/test')
      expect(entry.path).to eq('/projects/test')
    end

    it 'includes optional remote' do
      entry = registry.register(
        name: 'my-project',
        path: '/projects/my-project',
        remote: 'git@github.com:user/repo.git'
      )

      expect(entry.remote).to eq('git@github.com:user/repo.git')
    end

    it 'sets registered_at timestamp' do
      entry = registry.register(name: 'test', path: '/test')
      expect(entry.registered_at).to be_within(1).of(Time.now.utc)
    end

    it 'persists to file' do
      registry.register(name: 'test', path: '/test')

      expect(File.exist?(registry_path)).to be true
      content = File.read(registry_path)
      expect(content).to include('test')
    end

    it 'replaces entry with same name' do
      registry.register(name: 'test', path: '/old-path')
      registry.register(name: 'test', path: '/new-path')

      expect(registry.all.size).to eq(1)
      expect(registry.find('test').path).to eq('/new-path')
    end

    it 'replaces entry with same path' do
      registry.register(name: 'old-name', path: '/project')
      registry.register(name: 'new-name', path: '/project')

      expect(registry.all.size).to eq(1)
      expect(registry.find('new-name').path).to eq('/project')
    end
  end

  describe '#unregister' do
    before do
      registry.register(name: 'test', path: '/test')
    end

    it 'removes the entry' do
      result = registry.unregister('test')
      expect(result.name).to eq('test')
      expect(registry.find('test')).to be_nil
    end

    it 'returns nil for unknown name' do
      expect(registry.unregister('unknown')).to be_nil
    end
  end

  describe '#find' do
    before do
      registry.register(name: 'project-a', path: '/projects/a')
      registry.register(name: 'project-b', path: '/projects/b')
    end

    it 'finds entry by name' do
      entry = registry.find('project-a')
      expect(entry.name).to eq('project-a')
      expect(entry.path).to eq('/projects/a')
    end

    it 'returns nil for unknown name' do
      expect(registry.find('unknown')).to be_nil
    end
  end

  describe '#all' do
    before do
      registry.register(name: 'project-a', path: '/projects/a')
      registry.register(name: 'project-b', path: '/projects/b')
    end

    it 'returns all entries' do
      entries = registry.all
      expect(entries.size).to eq(2)
      expect(entries.map(&:name)).to contain_exactly('project-a', 'project-b')
    end

    it 'returns a copy' do
      entries = registry.all
      entries.clear
      expect(registry.all.size).to eq(2)
    end
  end

  describe '#path_for' do
    before do
      registry.register(name: 'test', path: '/projects/test')
    end

    it 'returns path for known name' do
      expect(registry.path_for('test')).to eq('/projects/test')
    end

    it 'returns nil for unknown name' do
      expect(registry.path_for('unknown')).to be_nil
    end
  end

  describe '#find_by_path' do
    before do
      registry.register(name: 'test', path: '/projects/test')
    end

    it 'finds entry by path' do
      entry = registry.find_by_path('/projects/test')
      expect(entry.name).to eq('test')
    end

    it 'handles path expansion' do
      entry = registry.find_by_path('/projects/../projects/test')
      expect(entry.name).to eq('test')
    end

    it 'returns nil for unknown path' do
      expect(registry.find_by_path('/unknown')).to be_nil
    end
  end

  describe '#exists?' do
    before do
      registry.register(name: 'test', path: '/test')
    end

    it 'returns true for registered name' do
      expect(registry.exists?('test')).to be true
    end

    it 'returns false for unknown name' do
      expect(registry.exists?('unknown')).to be false
    end
  end

  describe 'persistence' do
    it 'persists across instances' do
      registry.register(name: 'test', path: '/test')

      new_registry = described_class.new(registry_path: registry_path)
      expect(new_registry.find('test')).not_to be_nil
    end

    it 'handles empty file' do
      File.write(registry_path, '')
      expect(registry.all).to eq([])
    end

    it 'handles malformed lines gracefully' do
      File.write(registry_path, "valid\ninvalid json\n{\"name\":\"test\",\"path\":\"/test\"}\n")

      entries = registry.all
      expect(entries.size).to eq(1)
      expect(entries.first.name).to eq('test')
    end
  end
end
