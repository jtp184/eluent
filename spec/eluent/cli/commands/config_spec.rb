# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/config'

RSpec.describe Eluent::CLI::Commands::Config do
  let(:root_path) { Dir.mktmpdir }
  let(:global_config_path) { File.join(root_path, '.eluent', 'global_config.yaml') }

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump(
                                                                 'repo_name' => 'testrepo',
                                                                 'defaults' => { 'priority' => 2 }
                                                               ))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      "{\"_type\":\"header\",\"repo_name\":\"testrepo\"}\n"
    )

    allow(Dir).to receive(:pwd).and_return(root_path)

    # Stub the global config path
    stub_const('Eluent::CLI::Commands::Config::GLOBAL_CONFIG_PATH', global_config_path)
  end

  after do
    FileUtils.rm_rf(root_path)
  end

  def run_command(*args, robot_mode: false)
    described_class.new(args, robot_mode: robot_mode).run
  rescue Eluent::Storage::RepositoryNotFoundError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'show action' do
    it 'displays config' do
      output = capture_stdout { run_command('show', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['config']['repo_name']).to eq('testrepo')
    end

    it 'is the default action' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['config']).not_to be_nil
    end

    it 'returns 0' do
      expect(run_command('show', robot_mode: true)).to eq(0)
    end
  end

  describe 'show --global' do
    before do
      FileUtils.mkdir_p(File.dirname(global_config_path))
      File.write(global_config_path, YAML.dump('global_setting' => 'value'))
    end

    it 'shows global config' do
      output = capture_stdout { run_command('show', '--global', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['path']).to eq(global_config_path)
      expect(parsed['data']['config']['global_setting']).to eq('value')
    end
  end

  describe 'get action' do
    it 'gets value by key' do
      output = capture_stdout { run_command('get', 'repo_name', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['value']).to eq('testrepo')
    end

    it 'gets nested value by dot notation' do
      output = capture_stdout { run_command('get', 'defaults.priority', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['value']).to eq(2)
    end

    it 'returns nil for unknown key' do
      output = capture_stdout { run_command('get', 'nonexistent', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['value']).to be_nil
    end

    it 'returns error without key' do
      output = capture_stdout { run_command('get', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_REQUEST')
    end

    it 'returns 0' do
      expect(run_command('get', 'repo_name', robot_mode: true)).to eq(0)
    end
  end

  describe 'set action' do
    it 'sets value' do
      run_command('set', 'new_key', 'new_value')

      config = YAML.safe_load_file(File.join(root_path, '.eluent', 'config.yaml'))
      expect(config['new_key']).to eq('new_value')
    end

    it 'sets nested value' do
      run_command('set', 'defaults.issue_type', 'bug')

      config = YAML.safe_load_file(File.join(root_path, '.eluent', 'config.yaml'))
      expect(config['defaults']['issue_type']).to eq('bug')
    end

    it 'parses integer values' do
      run_command('set', 'max_items', '100')

      config = YAML.safe_load_file(File.join(root_path, '.eluent', 'config.yaml'))
      expect(config['max_items']).to eq(100)
    end

    it 'parses boolean values' do
      run_command('set', 'enabled', 'true')

      config = YAML.safe_load_file(File.join(root_path, '.eluent', 'config.yaml'))
      expect(config['enabled']).to be(true)
    end

    it 'returns 0 on success' do
      expect(run_command('set', 'key', 'value', robot_mode: true)).to eq(0)
    end

    it 'returns error without key' do
      output = capture_stdout { run_command('set', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_REQUEST')
    end

    it 'returns error without value' do
      output = capture_stdout { run_command('set', 'key', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_REQUEST')
    end
  end

  describe 'robot mode' do
    it 'outputs JSON for show' do
      output = capture_stdout { run_command('show', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['path']).to include('.eluent/config.yaml')
    end

    it 'outputs JSON for get' do
      output = capture_stdout { run_command('get', 'repo_name', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['key']).to eq('repo_name')
    end

    it 'outputs JSON for set' do
      output = capture_stdout { run_command('set', 'key', 'value', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['key']).to eq('key')
      expect(parsed['data']['value']).to eq('value')
    end
  end

  describe 'invalid action' do
    it 'returns error for unknown action' do
      output = capture_stdout { run_command('unknown', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_REQUEST')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el config/).to_stdout
    end

    it 'returns 0' do
      expect(run_command('--help')).to eq(0)
    end
  end

  private

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
