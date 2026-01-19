# frozen_string_literal: true

RSpec.describe Eluent::Sync::GitAdapter do
  let(:repo_path) { '/test/repo' }
  let(:adapter) { described_class.new(repo_path: repo_path) }

  def stub_git(*args, stdout: '', stderr: '', success: true)
    command = ['git', '-C', repo_path, *args]
    status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
    allow(Open3).to receive(:capture3).with(*command).and_return([stdout, stderr, status])
  end

  describe '#initialize' do
    it 'expands the repo path' do
      adapter = described_class.new(repo_path: '.')
      expect(adapter.repo_path).to eq(File.expand_path('.'))
    end
  end

  describe '#current_branch' do
    it 'returns the current branch name' do
      stub_git('rev-parse', '--abbrev-ref', 'HEAD', stdout: "main\n")

      expect(adapter.current_branch).to eq('main')
    end

    it 'raises DetachedHeadError when HEAD is detached' do
      stub_git('rev-parse', '--abbrev-ref', 'HEAD', stdout: "HEAD\n")

      expect { adapter.current_branch }.to raise_error(
        Eluent::Sync::DetachedHeadError,
        'Cannot sync: HEAD is detached'
      )
    end
  end

  describe '#current_commit' do
    it 'returns the current commit hash' do
      stub_git('rev-parse', 'HEAD', stdout: "abc123def456\n")

      expect(adapter.current_commit).to eq('abc123def456')
    end
  end

  describe '#remote_head' do
    before do
      stub_git('rev-parse', '--abbrev-ref', 'HEAD', stdout: "main\n")
    end

    it 'returns the remote HEAD commit hash' do
      stub_git('rev-parse', 'origin/main', stdout: "remote123\n")

      expect(adapter.remote_head).to eq('remote123')
    end

    it 'returns nil when remote branch does not exist' do
      stub_git('rev-parse', 'origin/main', stderr: 'fatal: not a valid object name', success: false)

      expect(adapter.remote_head).to be_nil
    end

    it 'accepts custom remote and branch' do
      stub_git('rev-parse', 'upstream/develop', stdout: "develop123\n")

      expect(adapter.remote_head(remote: 'upstream', branch: 'develop')).to eq('develop123')
    end
  end

  describe '#remote?' do
    it 'returns true when remote exists' do
      stub_git('remote', 'get-url', 'origin', stdout: "git@github.com:user/repo.git\n")

      expect(adapter.remote?).to be true
    end

    it 'returns false when remote does not exist' do
      stub_git('remote', 'get-url', 'origin', stderr: 'fatal: No such remote', success: false)

      expect(adapter.remote?).to be false
    end

    it 'accepts custom remote name' do
      stub_git('remote', 'get-url', 'upstream', stdout: "git@github.com:other/repo.git\n")

      expect(adapter.remote?(remote: 'upstream')).to be true
    end
  end

  describe '#clean?' do
    it 'returns true when working directory is clean' do
      stub_git('status', '--porcelain', stdout: '')

      expect(adapter.clean?).to be true
    end

    it 'returns false when there are uncommitted changes' do
      stub_git('status', '--porcelain', stdout: " M lib/file.rb\n")

      expect(adapter.clean?).to be false
    end
  end

  describe '#file_exists_at_commit?' do
    it 'returns true when file exists at commit' do
      stub_git('cat-file', '-e', 'abc123:path/to/file.rb', stdout: '')

      expect(adapter.file_exists_at_commit?(commit: 'abc123', path: 'path/to/file.rb')).to be true
    end

    it 'returns false when file does not exist at commit' do
      stub_git('cat-file', '-e', 'abc123:path/to/file.rb', success: false)

      expect(adapter.file_exists_at_commit?(commit: 'abc123', path: 'path/to/file.rb')).to be false
    end
  end

  describe '#show_file_at_commit' do
    it 'returns file content at specific commit' do
      content = "line 1\nline 2\n"
      stub_git('show', 'abc123:path/to/file.rb', stdout: content)

      expect(adapter.show_file_at_commit(commit: 'abc123', path: 'path/to/file.rb')).to eq(content)
    end

    it 'raises GitError when file not found' do
      stub_git('show', 'abc123:missing.rb', stderr: 'fatal: Path not found', success: false)

      expect do
        adapter.show_file_at_commit(commit: 'abc123', path: 'missing.rb')
      end.to raise_error(Eluent::Sync::GitError, 'File not found at commit')
    end
  end

  describe '#fetch' do
    it 'fetches from origin by default' do
      stub_git('fetch', 'origin', stdout: '')

      expect { adapter.fetch }.not_to raise_error
    end

    it 'fetches from specified remote' do
      stub_git('fetch', 'upstream', stdout: '')

      expect { adapter.fetch(remote: 'upstream') }.not_to raise_error
    end
  end

  describe '#pull' do
    it 'pulls from origin by default' do
      stub_git('pull', 'origin', stdout: '')

      expect { adapter.pull }.not_to raise_error
    end

    it 'pulls from specified remote and branch' do
      stub_git('pull', 'upstream', 'develop', stdout: '')

      expect { adapter.pull(remote: 'upstream', branch: 'develop') }.not_to raise_error
    end
  end

  describe '#push' do
    it 'pushes to origin by default' do
      stub_git('push', 'origin', stdout: '')

      expect { adapter.push }.not_to raise_error
    end

    it 'pushes to specified remote and branch' do
      stub_git('push', 'upstream', 'main', stdout: '')

      expect { adapter.push(remote: 'upstream', branch: 'main') }.not_to raise_error
    end
  end

  describe '#add' do
    it 'adds a single file' do
      stub_git('add', 'path/to/file.rb', stdout: '')

      expect { adapter.add(paths: 'path/to/file.rb') }.not_to raise_error
    end

    it 'adds multiple files' do
      stub_git('add', 'file1.rb', 'file2.rb', stdout: '')

      expect { adapter.add(paths: %w[file1.rb file2.rb]) }.not_to raise_error
    end
  end

  describe '#commit' do
    it 'creates a commit with the given message' do
      stub_git('commit', '-m', 'Test commit message', stdout: '')

      expect { adapter.commit(message: 'Test commit message') }.not_to raise_error
    end

    it 'raises GitError when commit fails' do
      stub_git('commit', '-m', 'Test message', stderr: 'nothing to commit', success: false)

      expect { adapter.commit(message: 'Test message') }.to raise_error(Eluent::Sync::GitError)
    end
  end

  describe '#merge_base' do
    it 'returns the merge base of two commits' do
      stub_git('merge-base', 'commit1', 'commit2', stdout: "base123\n")

      expect(adapter.merge_base('commit1', 'commit2')).to eq('base123')
    end

    it 'returns nil when no common ancestor exists' do
      stub_git('merge-base', 'commit1', 'commit2', stderr: 'fatal: Not a valid commit', success: false)

      expect(adapter.merge_base('commit1', 'commit2')).to be_nil
    end
  end

  describe '#diff_files' do
    it 'returns list of changed files between commits' do
      stub_git('diff', '--name-only', 'abc123', 'def456', stdout: "file1.rb\nfile2.rb\n")

      expect(adapter.diff_files(from: 'abc123', to: 'def456')).to eq(%w[file1.rb file2.rb])
    end

    it 'returns empty array when no files changed' do
      stub_git('diff', '--name-only', 'abc123', 'def456', stdout: '')

      expect(adapter.diff_files(from: 'abc123', to: 'def456')).to eq([])
    end

    it 'filters out empty lines' do
      stub_git('diff', '--name-only', 'abc123', 'def456', stdout: "file1.rb\n\nfile2.rb\n")

      expect(adapter.diff_files(from: 'abc123', to: 'def456')).to eq(%w[file1.rb file2.rb])
    end
  end

  describe '#log' do
    it 'returns log output with default format' do
      stub_git('log', '-1', '--format=%H', 'HEAD', stdout: "abc123def456\n")

      expect(adapter.log).to eq("abc123def456\n")
    end

    it 'accepts custom ref, count, and format' do
      stub_git('log', '-5', '--format=%s', 'main', stdout: "commit 1\ncommit 2\n")

      expect(adapter.log(ref: 'main', count: 5, format: '%s')).to eq("commit 1\ncommit 2\n")
    end
  end

  describe 'error handling' do
    it 'includes command in error' do
      stub_git('status', '--porcelain', stderr: 'fatal: not a git repository', success: false)

      expect { adapter.send(:run_git, 'status', '--porcelain') }.to raise_error do |error|
        expect(error).to be_a(Eluent::Sync::GitError)
        expect(error.command).to include('git')
        expect(error.exit_code).to eq(1)
      end
    end

    it 'uses stderr as error message when present' do
      stub_git('push', 'origin', stderr: 'Permission denied', success: false)

      expect { adapter.push }.to raise_error(Eluent::Sync::GitError, 'Permission denied')
    end

    it 'uses default message when stderr is empty' do
      stub_git('push', 'origin', stderr: '', success: false)

      expect { adapter.push }.to raise_error(Eluent::Sync::GitError, 'Git command failed')
    end
  end
end

RSpec.describe Eluent::Sync::GitError do
  describe '#initialize' do
    it 'stores command, stderr, and exit_code' do
      error = described_class.new('failed', command: 'git push', stderr: 'error output', exit_code: 128)

      expect(error.message).to eq('failed')
      expect(error.command).to eq('git push')
      expect(error.stderr).to eq('error output')
      expect(error.exit_code).to eq(128)
    end
  end
end

RSpec.describe Eluent::Sync::NoRemoteError do
  it 'has a default message' do
    error = described_class.new
    expect(error.message).to eq('No remote configured')
  end

  it 'accepts custom message' do
    error = described_class.new('Custom message')
    expect(error.message).to eq('Custom message')
  end
end

RSpec.describe Eluent::Sync::DetachedHeadError do
  it 'has a default message' do
    error = described_class.new
    expect(error.message).to eq('Cannot sync: HEAD is detached')
  end
end
