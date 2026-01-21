# frozen_string_literal: true

RSpec.describe Eluent::Storage::Paths, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { described_class.new(root_path) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
  end

  after { FakeFS.deactivate! }

  describe '#initialize' do
    it 'expands the root path' do
      paths = described_class.new('/project/../project')
      expect(paths.root).to eq('/project')
    end

    it 'stores the root path' do
      expect(paths.root).to eq('/project')
    end
  end

  describe 'path accessors' do
    describe '#eluent_dir' do
      it 'returns the .eluent directory path' do
        expect(paths.eluent_dir).to eq('/project/.eluent')
      end
    end

    describe '#data_file' do
      it 'returns the data.jsonl file path' do
        expect(paths.data_file).to eq('/project/.eluent/data.jsonl')
      end
    end

    describe '#ephemeral_file' do
      it 'returns the ephemeral.jsonl file path' do
        expect(paths.ephemeral_file).to eq('/project/.eluent/ephemeral.jsonl')
      end
    end

    describe '#config_file' do
      it 'returns the config.yaml file path' do
        expect(paths.config_file).to eq('/project/.eluent/config.yaml')
      end
    end

    describe '#formulas_dir' do
      it 'returns the formulas directory path' do
        expect(paths.formulas_dir).to eq('/project/.eluent/formulas')
      end
    end

    describe '#plugins_dir' do
      it 'returns the plugins directory path' do
        expect(paths.plugins_dir).to eq('/project/.eluent/plugins')
      end
    end

    describe '#gitignore_file' do
      it 'returns the .gitignore file path' do
        expect(paths.gitignore_file).to eq('/project/.eluent/.gitignore')
      end
    end

    describe '#sync_state_file' do
      it 'returns the .sync-state file path' do
        expect(paths.sync_state_file).to eq('/project/.eluent/.sync-state')
      end
    end

    describe '#git_dir' do
      it 'returns the .git directory path' do
        expect(paths.git_dir).to eq('/project/.git')
      end
    end

    describe '#git_config_file' do
      it 'returns the git config file path' do
        expect(paths.git_config_file).to eq('/project/.git/config')
      end
    end
  end

  describe '#data_file_exists?' do
    it 'returns false when data file does not exist' do
      expect(paths.data_file_exists?).to be false
    end

    it 'returns true when data file exists' do
      setup_eluent_directory(root_path)
      expect(paths.data_file_exists?).to be true
    end
  end

  describe '#ephemeral_exists?' do
    it 'returns false when ephemeral file does not exist' do
      expect(paths.ephemeral_exists?).to be false
    end

    it 'returns true when ephemeral file exists' do
      setup_eluent_directory(root_path)
      FileUtils.touch(paths.ephemeral_file)
      expect(paths.ephemeral_exists?).to be true
    end
  end

  describe '#git_repo?' do
    it 'returns false when .git does not exist' do
      expect(paths).not_to be_git_repo
    end

    it 'returns true when .git directory exists (normal repo)' do
      FileUtils.mkdir_p(paths.git_dir)
      expect(paths).to be_git_repo
    end

    it 'returns true when .git file exists (worktree)' do
      FileUtils.mkdir_p(root_path)
      File.write(paths.git_dir, "gitdir: /main/repo/.git/worktrees/my-worktree\n")
      expect(paths).to be_git_repo
    end
  end

  describe '#git_worktree?' do
    it 'returns false when .git does not exist' do
      expect(paths).not_to be_git_worktree
    end

    it 'returns false when .git is a directory (normal repo)' do
      FileUtils.mkdir_p(paths.git_dir)
      expect(paths).not_to be_git_worktree
    end

    it 'returns true when .git is a file with gitdir pointer' do
      FileUtils.mkdir_p(root_path)
      File.write(paths.git_dir, "gitdir: /main/repo/.git/worktrees/my-worktree\n")
      expect(paths).to be_git_worktree
    end

    it 'returns false when .git file has invalid content' do
      FileUtils.mkdir_p(root_path)
      File.write(paths.git_dir, "not a valid gitdir pointer\n")
      expect(paths).not_to be_git_worktree
    end
  end

  describe '#git_common_dir' do
    context 'with a normal repository (.git directory)' do
      before { FileUtils.mkdir_p(paths.git_dir) }

      it 'returns the .git directory' do
        expect(paths.git_common_dir).to eq('/project/.git')
      end
    end

    context 'with a git worktree (.git file)' do
      let(:main_git_dir) { '/main/repo/.git' }
      let(:worktree_git_dir) { "#{main_git_dir}/worktrees/my-worktree" }

      before do
        # Set up the main repo's .git structure
        FileUtils.mkdir_p(main_git_dir)
        FileUtils.mkdir_p(worktree_git_dir)

        # Create the worktree's .git file pointing to main repo
        FileUtils.mkdir_p(root_path)
        File.write(paths.git_dir, "gitdir: #{worktree_git_dir}\n")
      end

      it 'returns the main repository .git directory' do
        expect(paths.git_common_dir).to eq(main_git_dir)
      end
    end

    context 'with a relative gitdir path' do
      let(:main_git_dir) { '/project/../main-repo/.git' }
      let(:worktree_git_dir) { "#{main_git_dir}/worktrees/my-worktree" }
      let(:resolved_main_git) { '/main-repo/.git' }

      before do
        # Set up the main repo's .git structure
        FileUtils.mkdir_p(File.expand_path(main_git_dir))
        FileUtils.mkdir_p(File.expand_path(worktree_git_dir))

        # Create worktree .git file with relative path
        FileUtils.mkdir_p(root_path)
        File.write(paths.git_dir, "gitdir: ../main-repo/.git/worktrees/my-worktree\n")
      end

      it 'resolves the relative path correctly' do
        expect(paths.git_common_dir).to eq(resolved_main_git)
      end
    end

    context 'when .git does not exist' do
      it 'returns the expected .git path anyway' do
        expect(paths.git_common_dir).to eq('/project/.git')
      end
    end

    context 'when .git file has invalid content' do
      before do
        FileUtils.mkdir_p(root_path)
        File.write(paths.git_dir, "invalid content\n")
      end

      it 'falls back to the .git path' do
        expect(paths.git_common_dir).to eq('/project/.git')
      end
    end
  end

  describe '#git_config_file' do
    context 'with a normal repository' do
      before { FileUtils.mkdir_p(paths.git_dir) }

      it 'returns .git/config' do
        expect(paths.git_config_file).to eq('/project/.git/config')
      end
    end

    context 'with a git worktree' do
      let(:main_git_dir) { '/main/repo/.git' }
      let(:worktree_git_dir) { "#{main_git_dir}/worktrees/my-worktree" }

      before do
        FileUtils.mkdir_p(main_git_dir)
        FileUtils.mkdir_p(worktree_git_dir)
        FileUtils.mkdir_p(root_path)
        File.write(paths.git_dir, "gitdir: #{worktree_git_dir}\n")
      end

      it 'returns the main repository config file' do
        expect(paths.git_config_file).to eq("#{main_git_dir}/config")
      end
    end
  end
end
