# frozen_string_literal: true

RSpec.shared_context 'with warnings enabled' do
  around do |example|
    original_verbose = $VERBOSE
    $VERBOSE = true
    example.run
  ensure
    $VERBOSE = original_verbose
  end
end

RSpec.describe Eluent::Storage::ConfigError do
  it 'is a subclass of Eluent::Error' do
    expect(described_class).to be < Eluent::Error
  end
end

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

      context 'with invalid cleanup_days' do
        include_context 'with warnings enabled'

        it 'uses default and emits warning' do
          setup_config_file(root_path, { 'repo_name' => 'test', 'ephemeral' => { 'cleanup_days' => 1000 } })

          expect { config_loader.load }.to output(/warning/).to_stderr
        end
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

    context 'sync configuration' do
      it 'returns default sync config when not specified' do
        setup_config_file(root_path, { 'repo_name' => 'test' })

        config = config_loader.load
        expect(config['sync']['ledger_branch']).to be_nil
        expect(config['sync']['auto_claim_push']).to be true
        expect(config['sync']['claim_retries']).to eq(5)
        expect(config['sync']['claim_timeout_hours']).to be_nil
        expect(config['sync']['offline_mode']).to eq('local')
        expect(config['sync']['network_timeout']).to eq(30)
        expect(config['sync']['global_path_override']).to be_nil
      end

      it 'returns independent config objects that do not share references' do
        setup_config_file(root_path, { 'repo_name' => 'test' })

        config1 = config_loader.load
        config2 = config_loader.load

        # Mutating config1 should not affect config2
        config1['sync']['claim_retries'] = 999

        expect(config2['sync']['claim_retries']).to eq(5)
        expect(described_class::DEFAULT_CONFIG['sync']['claim_retries']).to eq(5)
      end

      context 'ledger_branch' do
        it 'accepts valid branch names' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => 'eluent-sync' }
                            })

          config = config_loader.load
          expect(config['sync']['ledger_branch']).to eq('eluent-sync')
        end

        it 'accepts branch names with slashes' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => 'feature/ledger-sync' }
                            })

          config = config_loader.load
          expect(config['sync']['ledger_branch']).to eq('feature/ledger-sync')
        end

        it 'raises ConfigError for invalid branch names' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => 'invalid..branch' }
                            })

          expect { config_loader.load }.to raise_error(
            Eluent::Storage::ConfigError,
            /Invalid sync\.ledger_branch.*not a valid git branch name/
          )
        end

        it 'raises ConfigError for branch names starting with dash' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => '-invalid' }
                            })

          expect { config_loader.load }.to raise_error(Eluent::Storage::ConfigError)
        end

        it 'treats empty string as nil (disabled)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => '' }
                            })

          config = config_loader.load
          expect(config['sync']['ledger_branch']).to be_nil
        end

        it 'treats whitespace-only string as nil (disabled)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => '   ' }
                            })

          config = config_loader.load
          expect(config['sync']['ledger_branch']).to be_nil
        end

        it 'strips whitespace from valid branch names' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'ledger_branch' => '  main  ' }
                            })

          config = config_loader.load
          expect(config['sync']['ledger_branch']).to eq('main')
        end
      end

      context 'auto_claim_push' do
        it 'accepts true' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => true }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be true
        end

        it 'accepts false' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => false }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be false
        end

        it 'treats string "false" as false' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => 'false' }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be false
        end

        it 'treats string "FALSE" as false (case-insensitive)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => 'FALSE' }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be false
        end

        it 'treats string "no" as false' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => 'no' }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be false
        end

        it 'treats string "0" as false' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => '0' }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be false
        end

        it 'treats string "yes" as true' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => 'yes' }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be true
        end

        it 'treats empty string as default' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'auto_claim_push' => '' }
                            })

          config = config_loader.load
          expect(config['sync']['auto_claim_push']).to be true # default is true
        end
      end

      context 'claim_retries' do
        it 'accepts valid values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => 10 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_retries']).to eq(10)
        end

        it 'accepts minimum boundary value (1)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => 1 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_retries']).to eq(1)
        end

        it 'accepts maximum boundary value (100)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => 100 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_retries']).to eq(100)
        end

        it 'handles string values by converting to integer' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => '10' }
                            })

          config = config_loader.load
          expect(config['sync']['claim_retries']).to eq(10)
        end

        it 'uses default when value is nil' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => nil }
                            })

          config = config_loader.load
          expect(config['sync']['claim_retries']).to eq(5)
        end
      end

      context 'claim_retries boundary warnings' do
        include_context 'with warnings enabled'

        it 'warns and uses minimum when value is 0' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => 0 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/claim_retries must be at least 1/).to_stderr
          expect(config['sync']['claim_retries']).to eq(1)
        end

        it 'warns and caps at maximum when value exceeds 100' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => 200 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/claim_retries capped at 100/).to_stderr
          expect(config['sync']['claim_retries']).to eq(100)
        end

        it 'warns and uses minimum for negative values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_retries' => -5 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/claim_retries must be at least 1/).to_stderr
          expect(config['sync']['claim_retries']).to eq(1)
        end
      end

      context 'claim_timeout_hours' do
        it 'accepts valid positive values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 24 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to eq(24)
        end

        it 'accepts maximum boundary value (720)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 720 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to eq(720)
        end

        it 'accepts string numeric values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => '24' }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to eq(24.0)
        end

        it 'accepts decimal values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 24.5 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to eq(24.5)
        end

        it 'accepts string decimal values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => '24.5' }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to eq(24.5)
        end

        it 'handles whitespace in string numeric values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => '  24  ' }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to eq(24.0)
        end

        it 'treats zero as nil (disabled)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 0 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to be_nil
        end

        it 'treats negative values as nil (disabled)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => -5 }
                            })

          config = config_loader.load
          expect(config['sync']['claim_timeout_hours']).to be_nil
        end
      end

      context 'claim_timeout_hours warnings' do
        include_context 'with warnings enabled'

        it 'warns for fractional hours' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 0.5 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/claim_timeout_hours < 1 may cause premature/).to_stderr
          expect(config['sync']['claim_timeout_hours']).to eq(0.5)
        end

        it 'warns and ignores non-numeric strings' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 'never' }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/claim_timeout_hours 'never' is not a number/).to_stderr
          expect(config['sync']['claim_timeout_hours']).to be_nil
        end

        it 'warns and caps extremely high values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'claim_timeout_hours' => 10_000 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/claim_timeout_hours capped at 720 hours/).to_stderr
          expect(config['sync']['claim_timeout_hours']).to eq(720.0)
        end
      end

      context 'offline_mode' do
        it 'accepts local mode' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'offline_mode' => 'local' }
                            })

          config = config_loader.load
          expect(config['sync']['offline_mode']).to eq('local')
        end

        it 'accepts fail mode' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'offline_mode' => 'fail' }
                            })

          config = config_loader.load
          expect(config['sync']['offline_mode']).to eq('fail')
        end

        it 'normalizes case' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'offline_mode' => 'LOCAL' }
                            })

          config = config_loader.load
          expect(config['sync']['offline_mode']).to eq('local')
        end

        it 'raises ConfigError for invalid values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'offline_mode' => 'invalid' }
                            })

          expect { config_loader.load }.to raise_error(
            Eluent::Storage::ConfigError,
            /Invalid sync\.offline_mode.*Valid options: local, fail/
          )
        end
      end

      context 'network_timeout' do
        it 'accepts valid values' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => 60 }
                            })

          config = config_loader.load
          expect(config['sync']['network_timeout']).to eq(60)
        end

        it 'accepts minimum boundary value (5)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => 5 }
                            })

          config = config_loader.load
          expect(config['sync']['network_timeout']).to eq(5)
        end

        it 'accepts maximum boundary value (300)' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => 300 }
                            })

          config = config_loader.load
          expect(config['sync']['network_timeout']).to eq(300)
        end

        it 'uses default when value is nil' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => nil }
                            })

          config = config_loader.load
          expect(config['sync']['network_timeout']).to eq(30)
        end

        it 'handles string values by converting to integer' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => '60' }
                            })

          config = config_loader.load
          expect(config['sync']['network_timeout']).to eq(60)
        end
      end

      context 'network_timeout boundary warnings' do
        include_context 'with warnings enabled'

        it 'warns and uses minimum when value is too low' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => 2 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/network_timeout must be at least 5s.*using 5/).to_stderr
          expect(config['sync']['network_timeout']).to eq(5)
        end

        it 'warns and caps when value exceeds maximum' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'network_timeout' => 600 }
                            })

          config = nil
          expect { config = config_loader.load }.to output(/network_timeout capped at 300s/).to_stderr
          expect(config['sync']['network_timeout']).to eq(300)
        end
      end

      context 'global_path_override' do
        it 'accepts valid paths' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'global_path_override' => '/custom/eluent' }
                            })

          config = config_loader.load
          expect(config['sync']['global_path_override']).to eq('/custom/eluent')
        end

        it 'expands relative paths' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'global_path_override' => '~/eluent-data' }
                            })

          config = config_loader.load
          expect(config['sync']['global_path_override']).to eq(File.expand_path('~/eluent-data'))
        end

        it 'treats empty string as nil' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'global_path_override' => '' }
                            })

          config = config_loader.load
          expect(config['sync']['global_path_override']).to be_nil
        end

        it 'raises ConfigError for paths starting with dash' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'global_path_override' => '-bad-path' }
                            })

          expect { config_loader.load }.to raise_error(
            Eluent::Storage::ConfigError,
            /cannot start with '-'/
          )
        end

        it 'treats whitespace-only string as nil' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => { 'global_path_override' => '   ' }
                            })

          config = config_loader.load
          expect(config['sync']['global_path_override']).to be_nil
        end
      end

      context 'with non-hash sync value' do
        it 'returns defaults when sync is a string' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => 'invalid'
                            })

          config = config_loader.load
          expect(config['sync']['ledger_branch']).to be_nil
          expect(config['sync']['auto_claim_push']).to be true
          expect(config['sync']['claim_retries']).to eq(5)
        end

        it 'returns defaults when sync is an array' do
          setup_config_file(root_path, {
                              'repo_name' => 'test',
                              'sync' => %w[a b c]
                            })

          config = config_loader.load
          expect(config['sync']['offline_mode']).to eq('local')
        end
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

    it 'returns independent config objects that do not share references with DEFAULT_CONFIG' do
      config1 = config_loader.write_initial(repo_name: 'repo1')
      config2 = config_loader.write_initial(repo_name: 'repo2')

      # Mutating config1 should not affect config2 or DEFAULT_CONFIG
      config1['sync']['claim_retries'] = 999

      expect(config2['sync']['claim_retries']).to eq(5)
      expect(described_class::DEFAULT_CONFIG['sync']['claim_retries']).to eq(5)
    end

    it 'includes sync configuration in the written file' do
      config_loader.write_initial(repo_name: 'newrepo')

      content = YAML.safe_load_file(paths.config_file)
      expect(content['sync']).to be_a(Hash)
      expect(content['sync']['offline_mode']).to eq('local')
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
