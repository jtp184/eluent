# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/init'

RSpec.describe Eluent::CLI::Commands::Init do
  let(:root_path) { Dir.mktmpdir }

  before do
    allow(Dir).to receive(:pwd).and_return(root_path)
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

  describe 'initialization' do
    it 'creates .eluent directory structure' do
      run_command

      expect(File.directory?(File.join(root_path, '.eluent'))).to be true
      expect(File.directory?(File.join(root_path, '.eluent', 'formulas'))).to be true
    end

    it 'creates config.yaml with repo_name' do
      run_command

      config_path = File.join(root_path, '.eluent', 'config.yaml')
      expect(File.exist?(config_path)).to be true

      config = YAML.safe_load_file(config_path)
      expect(config['repo_name']).not_to be_nil
    end

    it 'creates data.jsonl with header' do
      run_command

      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      expect(File.exist?(data_path)).to be true

      header = JSON.parse(File.readlines(data_path).first)
      expect(header['_type']).to eq('header')
      expect(header['repo_name']).not_to be_nil
    end

    it 'returns 0 on success' do
      expect(run_command).to eq(0)
    end

    it 'outputs success message' do
      expect { run_command }.to output(/Initialized/).to_stdout
    end
  end

  describe '--name option' do
    it 'uses custom repo name' do
      run_command('--name', 'myproject')

      config_path = File.join(root_path, '.eluent', 'config.yaml')
      config = YAML.safe_load_file(config_path)
      expect(config['repo_name']).to eq('myproject')
    end
  end

  describe 'REPO_EXISTS error' do
    before do
      FileUtils.mkdir_p(File.join(root_path, '.eluent'))
      File.write(File.join(root_path, '.eluent', 'data.jsonl'), "{\"_type\":\"header\"}\n")
    end

    it 'returns error if already initialized' do
      expect(run_command).to eq(1)
    end

    it 'outputs error message in robot mode' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['message']).to match(/already exists/i)
    end
  end

  describe 'robot mode' do
    it 'outputs JSON' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['path']).to include('.eluent')
      expect(parsed['data']['repo_name']).not_to be_nil
    end

    it 'outputs JSON error for REPO_EXISTS' do
      FileUtils.mkdir_p(File.join(root_path, '.eluent'))
      File.write(File.join(root_path, '.eluent', 'data.jsonl'), "{\"_type\":\"header\"}\n")

      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('REPO_EXISTS')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el init/).to_stdout
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

  def capture_stderr
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original_stderr
  end
end
