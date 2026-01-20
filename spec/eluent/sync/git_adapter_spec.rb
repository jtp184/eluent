# frozen_string_literal: true

# ==============================================================================
# GitAdapter Specs
# ==============================================================================
# Tests for the git CLI wrapper. Organized by method category:
# - Core adapter (query methods, basic operations)
# - Error classes
# - Branch operations
# - Worktree operations
# - Ledger branch operations (network-aware)

RSpec.describe Eluent::Sync::GitAdapter do
  let(:repo_path) { '/test/repo' }
  let(:adapter) { described_class.new(repo_path: repo_path) }

  def stub_git(*args, stdout: '', stderr: '', success: true)
    command = ['git', '-C', repo_path, *args]
    status = instance_double(Process::Status, success?: success, exitstatus: success ? 0 : 1)
    allow(Open3).to receive(:capture3).with(*command).and_return([stdout, stderr, status])
  end

  # Helper to create a mock wait thread that mimics Process::Waiter
  def mock_wait_thread(status:, pid: 12_345)
    thread = Object.new
    thread.define_singleton_method(:pid) { pid }
    thread.define_singleton_method(:join) { |_timeout = nil| thread }
    thread.define_singleton_method(:value) { status }
    thread
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

    it 'raises ArgumentError when paths is empty' do
      expect { adapter.add(paths: []) }.to raise_error(ArgumentError, 'No paths provided to add')
    end

    it 'raises ArgumentError when paths is nil' do
      expect { adapter.add(paths: nil) }.to raise_error(ArgumentError, 'No paths provided to add')
    end

    it 'filters out empty and whitespace-only paths' do
      stub_git('add', 'file.rb', stdout: '')

      expect { adapter.add(paths: ['file.rb', '', '   ', nil]) }.not_to raise_error
    end

    it 'raises when all paths are empty or nil' do
      expect { adapter.add(paths: ['', nil, '  ']) }.to raise_error(ArgumentError, 'No paths provided to add')
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

    it 'raises ArgumentError when message is nil' do
      expect { adapter.commit(message: nil) }.to raise_error(ArgumentError, 'Commit message cannot be empty')
    end

    it 'raises ArgumentError when message is empty' do
      expect { adapter.commit(message: '') }.to raise_error(ArgumentError, 'Commit message cannot be empty')
    end

    it 'raises ArgumentError when message is whitespace-only' do
      expect { adapter.commit(message: '   ') }.to raise_error(ArgumentError, 'Commit message cannot be empty')
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

  # ----------------------------------------------------------------------------
  # Branch Operations
  # ----------------------------------------------------------------------------

  describe '#branch_exists?' do
    it 'returns true when local branch exists' do
      stub_git('rev-parse', '--verify', 'refs/heads/main', stdout: 'abc123')

      expect(adapter.branch_exists?('main')).to be true
    end

    it 'returns false when local branch does not exist' do
      stub_git('rev-parse', '--verify', 'refs/heads/nonexistent', success: false)

      expect(adapter.branch_exists?('nonexistent')).to be false
    end

    it 'returns true when remote branch exists' do
      stub_git('ls-remote', '--heads', 'origin', 'main', stdout: "abc123\trefs/heads/main\n")

      expect(adapter.branch_exists?('main', remote: 'origin')).to be true
    end

    it 'returns false when remote branch does not exist' do
      stub_git('ls-remote', '--heads', 'origin', 'nonexistent', stdout: '')

      expect(adapter.branch_exists?('nonexistent', remote: 'origin')).to be false
    end

    it 'does not match partial branch names on remote' do
      stub_git('ls-remote', '--heads', 'origin', 'main', stdout: "abc123\trefs/heads/mainx\n")

      expect(adapter.branch_exists?('main', remote: 'origin')).to be false
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.branch_exists?('bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end
  end

  describe '#create_orphan_branch' do
    it 'creates an orphan branch with default message' do
      stub_git('rev-parse', '--verify', 'refs/heads/new-branch', success: false)
      stub_git('checkout', '--orphan', 'new-branch', stdout: '')
      stub_git('rm', '-rf', '.', stdout: '')
      stub_git('commit', '--allow-empty', '-m', 'Initialize branch', stdout: '')

      expect { adapter.create_orphan_branch('new-branch') }.not_to raise_error
    end

    it 'creates an orphan branch with custom message' do
      stub_git('rev-parse', '--verify', 'refs/heads/new-branch', success: false)
      stub_git('checkout', '--orphan', 'new-branch', stdout: '')
      stub_git('rm', '-rf', '.', stdout: '')
      stub_git('commit', '--allow-empty', '-m', 'Custom init', stdout: '')

      expect { adapter.create_orphan_branch('new-branch', initial_message: 'Custom init') }
        .not_to raise_error
    end

    it 'raises BranchError when branch already exists' do
      stub_git('rev-parse', '--verify', 'refs/heads/existing', stdout: 'abc123')

      expect { adapter.create_orphan_branch('existing') }
        .to raise_error(Eluent::Sync::BranchError, /already exists/)
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.create_orphan_branch('bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end
  end

  describe '#checkout' do
    it 'checks out an existing branch' do
      stub_git('checkout', 'feature', stdout: '')

      expect { adapter.checkout('feature') }.not_to raise_error
    end

    it 'creates and checks out a new branch with create: true' do
      stub_git('checkout', '-b', 'new-feature', stdout: '')

      expect { adapter.checkout('new-feature', create: true) }.not_to raise_error
    end

    it 'raises BranchError when checkout fails' do
      stub_git('checkout', 'nonexistent', stderr: 'branch not found', success: false)

      expect { adapter.checkout('nonexistent') }
        .to raise_error(Eluent::Sync::BranchError, /Failed to checkout/)
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.checkout('bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end
  end

  # ----------------------------------------------------------------------------
  # Worktree Operations
  # ----------------------------------------------------------------------------

  describe '#worktree_list' do
    it 'parses porcelain output correctly' do
      output = <<~OUTPUT
        worktree /main/repo
        HEAD abc123def456
        branch refs/heads/main

        worktree /other/worktree
        HEAD def789abc123
        branch refs/heads/feature

      OUTPUT

      stub_git('worktree', 'list', '--porcelain', stdout: output)

      worktrees = adapter.worktree_list

      expect(worktrees.size).to eq(2)
      expect(worktrees[0].path).to eq('/main/repo')
      expect(worktrees[0].commit).to eq('abc123def456')
      expect(worktrees[0].branch).to eq('main')
      expect(worktrees[1].path).to eq('/other/worktree')
      expect(worktrees[1].branch).to eq('feature')
    end

    it 'handles detached HEAD worktrees' do
      output = <<~OUTPUT
        worktree /detached
        HEAD abc123
        detached

      OUTPUT

      stub_git('worktree', 'list', '--porcelain', stdout: output)

      worktrees = adapter.worktree_list

      expect(worktrees.size).to eq(1)
      expect(worktrees[0].detached?).to be true
    end

    it 'handles bare worktrees' do
      output = <<~OUTPUT
        worktree /bare
        bare

      OUTPUT

      stub_git('worktree', 'list', '--porcelain', stdout: output)

      worktrees = adapter.worktree_list

      expect(worktrees.size).to eq(1)
      expect(worktrees[0].bare?).to be true
    end

    it 'raises WorktreeError on failure' do
      stub_git('worktree', 'list', '--porcelain', stderr: 'fatal error', success: false)

      expect { adapter.worktree_list }
        .to raise_error(Eluent::Sync::WorktreeError, /Failed to list worktrees/)
    end
  end

  describe '#worktree_add' do
    let(:worktree_path) { '/tmp/test-worktree' }
    let(:expanded_path) { File.expand_path(worktree_path) }

    before do
      allow(File).to receive(:exist?).with(expanded_path).and_return(false)
    end

    it 'adds a new worktree' do
      stub_git('worktree', 'add', expanded_path, 'feature', stdout: '')
      stub_git('worktree', 'list', '--porcelain',
               stdout: "worktree #{expanded_path}\nHEAD abc123\nbranch refs/heads/feature\n")

      result = adapter.worktree_add(path: worktree_path, branch: 'feature')

      expect(result.path).to eq(expanded_path)
      expect(result.branch).to eq('feature')
    end

    it 'returns existing worktree if path already exists as worktree' do
      allow(File).to receive(:exist?).with(expanded_path).and_return(true)
      stub_git('worktree', 'list', '--porcelain',
               stdout: "worktree #{expanded_path}\nHEAD abc123\nbranch refs/heads/feature\n")

      result = adapter.worktree_add(path: worktree_path, branch: 'feature')

      expect(result.path).to eq(expanded_path)
    end

    it 'raises WorktreeError if path exists but is not a worktree' do
      allow(File).to receive(:exist?).with(expanded_path).and_return(true)
      stub_git('worktree', 'list', '--porcelain', stdout: "worktree /other/path\nHEAD abc\nbranch refs/heads/main\n")

      expect { adapter.worktree_add(path: worktree_path, branch: 'feature') }
        .to raise_error(Eluent::Sync::WorktreeError, /exists but is not a valid worktree/)
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.worktree_add(path: worktree_path, branch: 'bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end
  end

  describe '#worktree_remove' do
    let(:worktree_path) { '/tmp/test-worktree' }
    let(:expanded_path) { File.expand_path(worktree_path) }

    it 'removes an existing worktree' do
      stub_git('worktree', 'list', '--porcelain',
               stdout: "worktree #{expanded_path}\nHEAD abc123\nbranch refs/heads/feature\n")
      stub_git('worktree', 'remove', expanded_path, stdout: '')

      expect(adapter.worktree_remove(path: worktree_path)).to be true
    end

    it 'removes with force flag when specified' do
      stub_git('worktree', 'list', '--porcelain',
               stdout: "worktree #{expanded_path}\nHEAD abc123\nbranch refs/heads/feature\n")
      stub_git('worktree', 'remove', '--force', expanded_path, stdout: '')

      expect(adapter.worktree_remove(path: worktree_path, force: true)).to be true
    end

    it 'returns true when worktree does not exist (idempotent)' do
      stub_git('worktree', 'list', '--porcelain', stdout: "worktree /other/path\nHEAD abc\nbranch refs/heads/main\n")

      expect(adapter.worktree_remove(path: worktree_path)).to be true
    end

    it 'raises WorktreeError on failure' do
      stub_git('worktree', 'list', '--porcelain',
               stdout: "worktree #{expanded_path}\nHEAD abc123\nbranch refs/heads/feature\n")
      stub_git('worktree', 'remove', expanded_path, stderr: 'locked', success: false)

      expect { adapter.worktree_remove(path: worktree_path) }
        .to raise_error(Eluent::Sync::WorktreeError, /Failed to remove/)
    end
  end

  describe '#worktree_prune' do
    it 'prunes worktrees successfully' do
      stub_git('worktree', 'prune', stdout: '')

      expect { adapter.worktree_prune }.not_to raise_error
    end

    it 'raises WorktreeError on failure' do
      stub_git('worktree', 'prune', stderr: 'error', success: false)

      expect { adapter.worktree_prune }
        .to raise_error(Eluent::Sync::WorktreeError, /Failed to prune/)
    end
  end

  describe '#run_git_in_worktree' do
    let(:worktree_path) { '/tmp/test-worktree' }
    let(:expanded_path) { File.expand_path(worktree_path) }

    before do
      stub_git('worktree', 'list', '--porcelain',
               stdout: "worktree #{expanded_path}\nHEAD abc123\nbranch refs/heads/feature\n")
    end

    it 'executes git command in worktree' do
      command = ['git', '-C', expanded_path, 'status']
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(Open3).to receive(:capture3).with(*command).and_return(['clean', '', status])

      result = adapter.run_git_in_worktree(worktree_path, 'status')

      expect(result).to eq('clean')
    end

    it 'raises WorktreeError for invalid worktree path' do
      stub_git('worktree', 'list', '--porcelain', stdout: "worktree /other/path\nHEAD abc\nbranch refs/heads/main\n")

      expect { adapter.run_git_in_worktree('/invalid/path', 'status') }
        .to raise_error(Eluent::Sync::WorktreeError, /not a valid worktree/)
    end

    it 'raises GitError when command fails' do
      command = ['git', '-C', expanded_path, 'bad-command']
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Open3).to receive(:capture3).with(*command).and_return(['', 'unknown command', status])

      expect { adapter.run_git_in_worktree(worktree_path, 'bad-command') }
        .to raise_error(Eluent::Sync::GitError, 'unknown command')
    end
  end

  # ----------------------------------------------------------------------------
  # Ledger Branch Operations (Network-Aware)
  # ----------------------------------------------------------------------------

  describe '#fetch_branch' do
    it 'fetches a specific branch from remote' do
      command = ['git', '-C', repo_path, 'fetch', 'origin', 'eluent-sync']
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      stdin = instance_double(IO)
      stdout_io = instance_double(IO)
      stderr_io = instance_double(IO)
      wait_thread = mock_wait_thread(status: status)

      allow(stdin).to receive(:close)
      allow(stdout_io).to receive(:read).and_return('')
      allow(stderr_io).to receive(:read).and_return('')

      allow(Open3).to receive(:popen3).with(*command).and_yield(stdin, stdout_io, stderr_io, wait_thread)

      expect { adapter.fetch_branch(remote: 'origin', branch: 'eluent-sync') }.not_to raise_error
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.fetch_branch(remote: 'origin', branch: 'bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end

    it 'raises ArgumentError for zero timeout' do
      expect { adapter.fetch_branch(remote: 'origin', branch: 'main', timeout: 0) }
        .to raise_error(ArgumentError, 'Timeout must be positive')
    end

    it 'raises ArgumentError for negative timeout' do
      expect { adapter.fetch_branch(remote: 'origin', branch: 'main', timeout: -5) }
        .to raise_error(ArgumentError, 'Timeout must be positive')
    end

    it 'raises ArgumentError for non-numeric timeout' do
      expect { adapter.fetch_branch(remote: 'origin', branch: 'main', timeout: 'fast') }
        .to raise_error(ArgumentError, 'Timeout must be positive')
    end
  end

  describe '#push_branch' do
    it 'pushes a branch to remote' do
      command = ['git', '-C', repo_path, 'push', 'origin', 'eluent-sync']
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      stdin = instance_double(IO)
      stdout_io = instance_double(IO)
      stderr_io = instance_double(IO)
      wait_thread = mock_wait_thread(status: status)

      allow(stdin).to receive(:close)
      allow(stdout_io).to receive(:read).and_return('')
      allow(stderr_io).to receive(:read).and_return('')

      allow(Open3).to receive(:popen3).with(*command).and_yield(stdin, stdout_io, stderr_io, wait_thread)

      expect { adapter.push_branch(remote: 'origin', branch: 'eluent-sync') }.not_to raise_error
    end

    it 'pushes with -u flag when set_upstream is true' do
      command = ['git', '-C', repo_path, 'push', '-u', 'origin', 'eluent-sync']
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      stdin = instance_double(IO)
      stdout_io = instance_double(IO)
      stderr_io = instance_double(IO)
      wait_thread = mock_wait_thread(status: status)

      allow(stdin).to receive(:close)
      allow(stdout_io).to receive(:read).and_return('')
      allow(stderr_io).to receive(:read).and_return('')

      allow(Open3).to receive(:popen3).with(*command).and_yield(stdin, stdout_io, stderr_io, wait_thread)

      expect { adapter.push_branch(remote: 'origin', branch: 'eluent-sync', set_upstream: true) }
        .not_to raise_error
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.push_branch(remote: 'origin', branch: 'bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end
  end

  describe '#remote_branch_sha' do
    it 'returns SHA when branch exists on remote' do
      stub_git('ls-remote', 'origin', 'refs/heads/eluent-sync',
               stdout: "abc123def456789\trefs/heads/eluent-sync\n")

      expect(adapter.remote_branch_sha(remote: 'origin', branch: 'eluent-sync'))
        .to eq('abc123def456789')
    end

    it 'returns nil when branch does not exist on remote' do
      stub_git('ls-remote', 'origin', 'refs/heads/nonexistent', stdout: '')

      expect(adapter.remote_branch_sha(remote: 'origin', branch: 'nonexistent')).to be_nil
    end

    it 'returns nil when ls-remote fails' do
      stub_git('ls-remote', 'origin', 'refs/heads/eluent-sync', success: false)

      expect(adapter.remote_branch_sha(remote: 'origin', branch: 'eluent-sync')).to be_nil
    end

    it 'raises BranchError for invalid branch names' do
      expect { adapter.remote_branch_sha(remote: 'origin', branch: 'bad branch') }
        .to raise_error(Eluent::Sync::BranchError, /Invalid branch name/)
    end
  end
end

# ==============================================================================
# Error Classes
# ==============================================================================
# These errors form a hierarchy under GitError, each representing
# a specific failure mode in git operations.

RSpec.describe Eluent::Sync::GitError do
  it 'stores diagnostic information for debugging' do
    error = described_class.new('failed', command: 'git push', stderr: 'error output', exit_code: 128)

    expect(error.message).to eq('failed')
    expect(error.command).to eq('git push')
    expect(error.stderr).to eq('error output')
    expect(error.exit_code).to eq(128)
  end
end

RSpec.describe Eluent::Sync::NoRemoteError do
  it 'defaults to a descriptive message' do
    error = described_class.new
    expect(error.message).to eq('No remote configured')
  end

  it 'accepts custom message for specific remote names' do
    error = described_class.new("Remote 'upstream' not found")
    expect(error.message).to eq("Remote 'upstream' not found")
  end
end

RSpec.describe Eluent::Sync::DetachedHeadError do
  it 'explains the detached HEAD state' do
    error = described_class.new
    expect(error.message).to eq('Cannot sync: HEAD is detached')
  end
end

RSpec.describe Eluent::Sync::WorktreeError do
  it 'inherits diagnostic attributes from GitError' do
    error = described_class.new('worktree failed', command: 'git worktree add', exit_code: 1)
    expect(error.message).to eq('worktree failed')
    expect(error.command).to eq('git worktree add')
    expect(error.exit_code).to eq(1)
  end
end

RSpec.describe Eluent::Sync::GitTimeoutError do
  it 'includes the timeout duration for debugging' do
    error = described_class.new('timed out', timeout: 30, command: 'git fetch')
    expect(error.message).to eq('timed out')
    expect(error.timeout).to eq(30)
    expect(error.command).to eq('git fetch')
  end
end

RSpec.describe Eluent::Sync::BranchError do
  describe '.validate_branch_name!' do
    it 'accepts common valid branch naming patterns' do
      %w[main feature/test fix-123 eluent-sync foo@bar v1.0.0].each do |name|
        expect { described_class.validate_branch_name!(name) }.not_to raise_error
      end
    end

    it 'rejects nil and empty strings' do
      expect { described_class.validate_branch_name!(nil) }
        .to raise_error(described_class, /Invalid branch name/)
      expect { described_class.validate_branch_name!('') }
        .to raise_error(described_class, /Invalid branch name/)
    end

    it 'rejects names starting with dash (looks like option)' do
      expect { described_class.validate_branch_name!('-bad') }
        .to raise_error(described_class, /Invalid branch name/)
    end

    it 'rejects names with spaces' do
      expect { described_class.validate_branch_name!('bad branch') }
        .to raise_error(described_class, /Invalid branch name/)
    end

    it 'rejects ".." (reserved for revision ranges)' do
      expect { described_class.validate_branch_name!('bad..name') }
        .to raise_error(described_class, /Invalid branch name/)
    end

    it 'rejects refspec special characters (~, ^, :)' do
      %w[bad~name bad^name bad:name].each do |name|
        expect { described_class.validate_branch_name!(name) }
          .to raise_error(described_class, /Invalid branch name/)
      end
    end

    it 'rejects "@" alone (reserved alias for HEAD)' do
      expect { described_class.validate_branch_name!('@') }
        .to raise_error(described_class, /Invalid branch name/)
    end

    it 'rejects "@{" (reserved for reflog syntax)' do
      expect { described_class.validate_branch_name!('foo@{1}') }
        .to raise_error(described_class, /Invalid branch name/)
    end

    it 'rejects path-like invalid patterns (/, //, trailing /)' do
      %w[/foo foo/ foo//bar].each do |name|
        expect { described_class.validate_branch_name!(name) }
          .to raise_error(described_class, /Invalid branch name/)
      end
    end

    it 'rejects trailing dot and .lock suffix (reserved by git)' do
      %w[foo. foo.lock].each do |name|
        expect { described_class.validate_branch_name!(name) }
          .to raise_error(described_class, /Invalid branch name/)
      end
    end
  end
end

RSpec.describe Eluent::Sync::WorktreeInfo do
  it 'identifies bare worktrees' do
    info = described_class.new(path: '/repo', commit: 'abc', branch: '(bare)')
    expect(info.bare?).to be true
    expect(info.detached?).to be false
  end

  it 'identifies detached HEAD worktrees' do
    info = described_class.new(path: '/repo', commit: 'abc', branch: '(detached HEAD)')
    expect(info.bare?).to be false
    expect(info.detached?).to be true
  end

  it 'identifies normal worktrees' do
    info = described_class.new(path: '/repo', commit: 'abc', branch: 'main')
    expect(info.bare?).to be false
    expect(info.detached?).to be false
  end
end
