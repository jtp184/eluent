# frozen_string_literal: true

RSpec.describe Eluent::Storage::GlobalPaths, :filesystem do
  let(:repo_name) { 'my-project' }
  let(:global_paths) { described_class.new(repo_name: repo_name) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    # Create home directory for FakeFS
    FileUtils.mkdir_p(File.expand_path('~'))
  end

  after { FakeFS.deactivate! }

  describe '#initialize' do
    it 'stores the repo name' do
      expect(global_paths.repo_name).to eq('my-project')
    end

    it 'stores the original repo name' do
      expect(global_paths.original_repo_name).to eq('my-project')
    end

    context 'with sanitization needed' do
      let(:repo_name) { 'my/project:name' }

      it 'sanitizes invalid characters' do
        expect(global_paths.repo_name).to eq('my_project_name')
      end

      it 'preserves original name' do
        expect(global_paths.original_repo_name).to eq('my/project:name')
      end

      it 'reports sanitization occurred' do
        expect(global_paths).to be_name_was_sanitized
      end
    end

    context 'without sanitization needed' do
      it 'does not report sanitization' do
        expect(global_paths).not_to be_name_was_sanitized
      end
    end

    context 'with nil repo name' do
      it 'raises GlobalPathsError' do
        expect { described_class.new(repo_name: nil) }
          .to raise_error(Eluent::Storage::GlobalPathsError, /repo_name is required/)
      end
    end

    context 'with empty repo name' do
      it 'raises GlobalPathsError' do
        expect { described_class.new(repo_name: '') }
          .to raise_error(Eluent::Storage::GlobalPathsError, /repo_name is required/)
      end
    end

    context 'with whitespace-only repo name' do
      it 'raises GlobalPathsError' do
        expect { described_class.new(repo_name: '   ') }
          .to raise_error(Eluent::Storage::GlobalPathsError, /repo_name is required/)
      end
    end

    context 'with path traversal attempt' do
      it 'sanitizes paths with slashes and dots' do
        paths = described_class.new(repo_name: 'my/../../../etc/passwd')
        # Slashes become _, then .. sequences become _
        expect(paths.repo_name).not_to include('/')
        expect(paths.repo_name).not_to include('..')
        expect(paths).to be_name_was_sanitized
      end

      it 'sanitizes leading dots' do
        paths = described_class.new(repo_name: '..hidden')
        expect(paths.repo_name).to eq('hidden')
        expect(paths).to be_name_was_sanitized
      end

      it 'sanitizes names that are only dots' do
        expect { described_class.new(repo_name: '...') }
          .to raise_error(Eluent::Storage::GlobalPathsError, /repo_name is required/)
      end

      it 'prevents directory escape via slashes' do
        paths = described_class.new(repo_name: '../../../etc')
        expect(paths.repo_name).not_to include('/')
        expect(paths.repo_name).not_to include('..')
        expect(paths.repo_dir).not_to include('../')
        expect(paths).to be_name_was_sanitized
      end

      it 'handles path traversal in middle of name' do
        paths = described_class.new(repo_name: 'project/../secret')
        expect(paths.repo_name).not_to include('/')
        expect(paths.repo_name).not_to include('..')
      end
    end

    context 'with leading/trailing dots' do
      it 'removes leading dots' do
        paths = described_class.new(repo_name: '.hidden-project')
        expect(paths.repo_name).to eq('hidden-project')
        expect(paths).to be_name_was_sanitized
      end

      it 'removes trailing dots' do
        paths = described_class.new(repo_name: 'project...')
        expect(paths.repo_name).to eq('project')
        expect(paths).to be_name_was_sanitized
      end

      it 'handles single leading dot' do
        paths = described_class.new(repo_name: '.gitignore')
        expect(paths.repo_name).to eq('gitignore')
      end
    end

    context 'with very long repo name' do
      let(:long_name) { 'a' * 300 }

      it 'truncates to MAX_REPO_NAME_LENGTH' do
        paths = described_class.new(repo_name: long_name)
        expect(paths.repo_name.length).to eq(described_class::MAX_REPO_NAME_LENGTH)
        expect(paths).to be_name_was_sanitized
      end

      it 'truncates names with special characters properly' do
        long_name_with_special = "#{'x' * 100}/#{'y' * 100}/#{'z' * 100}"
        paths = described_class.new(repo_name: long_name_with_special)
        expect(paths.repo_name.length).to be <= described_class::MAX_REPO_NAME_LENGTH
        expect(paths.repo_name).not_to include('/')
      end
    end

    context 'with leading/trailing whitespace' do
      it 'strips whitespace' do
        paths = described_class.new(repo_name: '  my-project  ')
        expect(paths.repo_name).to eq('my-project')
        expect(paths).to be_name_was_sanitized
      end

      it 'strips tabs and newlines' do
        paths = described_class.new(repo_name: "\t\nmy-project\n\t")
        expect(paths.repo_name).to eq('my-project')
      end
    end
  end

  describe '#global_dir' do
    context 'without XDG_DATA_HOME' do
      before { ENV.delete('XDG_DATA_HOME') }

      it 'returns ~/.eluent/' do
        expect(global_paths.global_dir).to eq(File.expand_path('~/.eluent'))
      end
    end

    context 'with XDG_DATA_HOME set' do
      before { ENV['XDG_DATA_HOME'] = '/custom/data' }
      after { ENV.delete('XDG_DATA_HOME') }

      it 'returns $XDG_DATA_HOME/eluent/' do
        expect(global_paths.global_dir).to eq('/custom/data/eluent')
      end
    end

    context 'with empty XDG_DATA_HOME' do
      before { ENV['XDG_DATA_HOME'] = '' }
      after { ENV.delete('XDG_DATA_HOME') }

      it 'falls back to ~/.eluent/' do
        expect(global_paths.global_dir).to eq(File.expand_path('~/.eluent'))
      end
    end

    context 'with XDG_DATA_HOME with trailing slash' do
      before { ENV['XDG_DATA_HOME'] = '/custom/data/' }
      after { ENV.delete('XDG_DATA_HOME') }

      it 'handles trailing slash correctly' do
        expect(global_paths.global_dir).to eq('/custom/data/eluent')
      end
    end

    context 'when HOME cannot be determined' do
      before do
        ENV.delete('XDG_DATA_HOME')
        allow(Dir).to receive(:home).and_raise(ArgumentError, "couldn't find HOME")
      end

      it 'raises GlobalPathsError with descriptive message' do
        expect { described_class.new(repo_name: 'test').global_dir }
          .to raise_error(Eluent::Storage::GlobalPathsError, /HOME environment variable/)
      end
    end
  end

  describe '#repo_dir' do
    it 'returns global_dir/<repo_name>/' do
      expect(global_paths.repo_dir).to eq(File.expand_path('~/.eluent/my-project'))
    end
  end

  describe '#sync_worktree_dir' do
    it 'returns repo_dir/.sync-worktree/' do
      expect(global_paths.sync_worktree_dir).to eq(File.expand_path('~/.eluent/my-project/.sync-worktree'))
    end
  end

  describe '#ledger_sync_state_file' do
    it 'returns repo_dir/.ledger-sync-state' do
      expect(global_paths.ledger_sync_state_file).to eq(File.expand_path('~/.eluent/my-project/.ledger-sync-state'))
    end
  end

  describe '#ledger_lock_file' do
    it 'returns repo_dir/.ledger.lock' do
      expect(global_paths.ledger_lock_file).to eq(File.expand_path('~/.eluent/my-project/.ledger.lock'))
    end
  end

  describe '#ensure_directories!' do
    it 'creates global_dir' do
      global_paths.ensure_directories!
      expect(Dir.exist?(global_paths.global_dir)).to be true
    end

    it 'creates repo_dir' do
      global_paths.ensure_directories!
      expect(Dir.exist?(global_paths.repo_dir)).to be true
    end

    it 'is idempotent' do
      global_paths.ensure_directories!
      expect { global_paths.ensure_directories! }.not_to raise_error
    end

    context 'when directory creation fails' do
      it 'raises GlobalPathsError with descriptive message' do
        allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES, 'Permission denied')

        expect { global_paths.ensure_directories! }
          .to raise_error(Eluent::Storage::GlobalPathsError, /Cannot create directories/)
      end
    end
  end

  describe '#writable?' do
    context 'when directories exist and are writable' do
      before { global_paths.ensure_directories! }

      it 'returns true' do
        expect(global_paths).to be_writable
      end
    end

    context 'when directories do not exist' do
      it 'returns false' do
        expect(global_paths).not_to be_writable
      end
    end

    context 'when global_dir exists but repo_dir does not' do
      before { FileUtils.mkdir_p(global_paths.global_dir) }

      it 'returns false' do
        expect(global_paths).not_to be_writable
      end
    end

    context 'when directory is not writable' do
      before do
        global_paths.ensure_directories!
        FileUtils.chmod(0o444, global_paths.repo_dir)
      end

      after do
        FileUtils.chmod(0o755, global_paths.repo_dir)
      end

      it 'returns false' do
        expect(global_paths).not_to be_writable
      end
    end
  end

  describe 'repo name sanitization' do
    {
      'valid-name' => 'valid-name',
      'name_with_underscore' => 'name_with_underscore',
      'path/with/slashes' => 'path_with_slashes',
      'back\\slashes' => 'back_slashes',
      'special:chars' => 'special_chars',
      'asterisk*star' => 'asterisk_star',
      'question?' => 'question_',
      'double"quote' => 'double_quote',
      'less<than>greater' => 'less_than_greater',
      'pipe|char' => 'pipe_char',
      'mixed/path:*?"<>|chars' => 'mixed_path_______chars'
    }.each do |input, expected|
      it "sanitizes '#{input}' to '#{expected}'" do
        # Suppress warnings for this test
        paths = nil
        expect { paths = described_class.new(repo_name: input) }.to output(/el:/).to_stderr.or output('').to_stderr
        expect(paths.repo_name).to eq(expected)
      end
    end
  end
end
