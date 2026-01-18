# frozen_string_literal: true

RSpec.describe Eluent::Storage::ConfigLoader, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }
  let(:config_loader) { described_class.new(paths: paths) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    setup_eluent_directory(root_path)
  end

  after { FakeFS.deactivate! }

  describe '#load' do
    context 'when config file does not exist' do
      it 'returns default config with inferred repo name' do
        config = config_loader.load
        expect(config['repo_name']).not_to be_nil
        expect(config['defaults']['priority']).to eq(2)
        expect(config['defaults']['issue_type']).to eq('task')
      end
    end

    context 'when config file exists' do
      it 'loads and validates the config' do
        config_content = {
          'repo_name' => 'myrepo',
          'defaults' => {
            'priority' => 1,
            'issue_type' => 'feature'
          }
        }
        setup_config_file(root_path, config_content)

        config = config_loader.load
        expect(config['repo_name']).to eq('myrepo')
        expect(config['defaults']['priority']).to eq(1)
        expect(config['defaults']['issue_type']).to eq('feature')
      end

      it 'uses defaults for missing values' do
        setup_config_file(root_path, { 'repo_name' => 'test' })

        config = config_loader.load
        expect(config['defaults']['priority']).to eq(2)
        expect(config['ephemeral']['cleanup_days']).to eq(7)
      end

      it 'validates repo_name format' do
        setup_config_file(root_path, { 'repo_name' => 'INVALID!' })

        config = config_loader.load
        # Should fall back to inferred name
        expect(config['repo_name']).not_to eq('INVALID!')
      end
    end

    context 'ephemeral configuration' do
      it 'accepts valid cleanup_days' do
        setup_config_file(root_path, { 'repo_name' => 'test', 'ephemeral' => { 'cleanup_days' => 14 } })

        config = config_loader.load
        expect(config['ephemeral']['cleanup_days']).to eq(14)
      end

      it 'uses default for invalid cleanup_days' do
        setup_config_file(root_path, { 'repo_name' => 'test', 'ephemeral' => { 'cleanup_days' => 1000 } })

        expect { config_loader.load }.to output(/warning/).to_stderr
      end
    end

    context 'compaction configuration' do
      it 'accepts valid tier values' do
        setup_config_file(root_path, {
                            'repo_name' => 'test',
                            'compaction' => { 'tier1_days' => 60, 'tier2_days' => 180 }
                          })

        config = config_loader.load
        expect(config['compaction']['tier1_days']).to eq(60)
        expect(config['compaction']['tier2_days']).to eq(180)
      end
    end
  end

  describe '#write_initial' do
    it 'creates config file with default values' do
      config_loader.write_initial(repo_name: 'newrepo')

      expect(File.exist?(paths.config_file)).to be true
      content = YAML.safe_load_file(paths.config_file)
      expect(content['repo_name']).to eq('newrepo')
    end

    it 'returns the config hash' do
      config = config_loader.write_initial(repo_name: 'newrepo')

      expect(config).to be_a(Hash)
      expect(config['repo_name']).to eq('newrepo')
    end
  end
end

RSpec.describe Eluent::Storage::RepoNameInferrer, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }
  let(:inferrer) { described_class.new(paths) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    FileUtils.mkdir_p(root_path)
  end

  after { FakeFS.deactivate! }

  describe '#infer' do
    context 'with git remote' do
      before do
        FileUtils.mkdir_p(paths.git_dir)
        File.write(paths.git_config_file, <<~GIT_CONFIG)
          [core]
              bare = false
          [remote "origin"]
              url = https://github.com/user/my-awesome-project.git
              fetch = +refs/heads/*:refs/remotes/origin/*
        GIT_CONFIG
      end

      it 'extracts repo name from git remote URL' do
        expect(inferrer.infer).to eq('my-awesome-project')
      end

      it 'removes .git suffix' do
        expect(inferrer.infer).not_to end_with('.git')
      end
    end

    context 'without git' do
      it 'uses directory name' do
        expect(inferrer.infer).to eq('project')
      end
    end

    context 'with special characters in directory name' do
      let(:root_path) { '/My_Project_123' }

      it 'normalizes to valid repo name' do
        name = inferrer.infer
        expect(name).to match(/\A[a-z][a-z0-9_-]*\z/)
      end
    end
  end
end
