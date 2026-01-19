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

  describe '#initialized?' do
    it 'returns false when data file does not exist' do
      expect(paths).not_to be_initialized
    end

    it 'returns true when data file exists' do
      setup_eluent_directory(root_path)
      expect(paths).to be_initialized
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
    it 'returns false when .git directory does not exist' do
      expect(paths).not_to be_git_repo
    end

    it 'returns true when .git directory exists' do
      FileUtils.mkdir_p(paths.git_dir)
      expect(paths).to be_git_repo
    end
  end
end
