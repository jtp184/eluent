# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/create'

RSpec.describe Eluent::CLI::Commands::Create do
  let(:root_path) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      "{\"_type\":\"header\",\"repo_name\":\"testrepo\"}\n"
    )

    allow(Dir).to receive(:pwd).and_return(root_path)
  end

  after do
    FileUtils.rm_rf(root_path)
  end

  def run_command(*args, robot_mode: false)
    described_class.new(args, robot_mode: robot_mode).run
  rescue Eluent::Storage::RepositoryNotFoundError,
         Eluent::Registry::IdNotFoundError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'creating an atom' do
    it 'creates atom with title' do
      expect { run_command('--title', 'Test task') }.to output(/Created/).to_stdout

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      expect(atom_line).not_to be_nil

      atom = JSON.parse(atom_line)
      expect(atom['title']).to eq('Test task')
    end

    it 'assigns ULID-format ID' do
      run_command('--title', 'Test task')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['id']).to match(/^testrepo-[0-9A-Z]{26}$/)
    end

    it 'uses default type (task)' do
      run_command('--title', 'Test task')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['issue_type']).to eq('task')
    end

    it 'returns 0 on success' do
      expect(run_command('--title', 'Test task')).to eq(0)
    end
  end

  describe 'options' do
    it 'sets --description' do
      run_command('--title', 'Test', '--description', 'A detailed description')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['description']).to eq('A detailed description')
    end

    it 'sets --type' do
      run_command('--title', 'Test', '--type', 'bug')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['issue_type']).to eq('bug')
    end

    it 'sets --priority' do
      run_command('--title', 'Test', '--priority', '0')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['priority']).to eq(0)
    end

    it 'sets --assignee' do
      run_command('--title', 'Test', '--assignee', 'alice')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['assignee']).to eq('alice')
    end

    it 'sets --label' do
      run_command('--title', 'Test', '--label', 'urgent', '--label', 'auth')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      atom = JSON.parse(atom_line)

      expect(atom['labels']).to include('urgent', 'auth')
    end

    it 'sets --parent' do
      # First create a parent
      run_command('--title', 'Parent epic', '--type', 'epic')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      parent_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      parent = JSON.parse(parent_line)

      # Create child with parent reference
      run_command('--title', 'Child task', '--parent', parent['id'])

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      child_line = data_lines.reverse.find { |line| line.include?('"title":"Child task"') }
      child = JSON.parse(child_line)

      expect(child['parent_id']).to eq(parent['id'])
    end
  end

  describe '--ephemeral flag' do
    it 'creates in ephemeral.jsonl' do
      run_command('--title', 'Ephemeral task', '--ephemeral')

      ephemeral_path = File.join(root_path, '.eluent', 'ephemeral.jsonl')
      expect(File.exist?(ephemeral_path)).to be true

      data_lines = File.readlines(ephemeral_path)
      atom_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      expect(atom_line).not_to be_nil
    end
  end

  describe '--blocking flag' do
    it 'creates dependency bond' do
      # Create target first
      run_command('--title', 'Target task')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      target_line = data_lines.find { |line| line.include?('"_type":"atom"') }
      target = JSON.parse(target_line)

      # Create blocker
      run_command('--title', 'Blocking task', '--blocking', target['id'])

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      bond_line = data_lines.find { |line| line.include?('"_type":"bond"') }
      expect(bond_line).not_to be_nil

      bond = JSON.parse(bond_line)
      expect(bond['source_id']).to eq(target['id'])
      expect(bond['dependency_type']).to eq('blocks')
    end
  end

  describe 'robot mode' do
    it 'outputs JSON with atom data' do
      output = capture_stdout { run_command('--title', 'Robot task', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['title']).to eq('Robot task')
      expect(parsed['data']['id']).to match(/^testrepo-/)
    end
  end

  describe 'error handling' do
    it 'returns error without title' do
      expect(run_command(robot_mode: true)).to eq(2)
    end

    it 'outputs error message without title' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['error']['message']).to match(/title is required/i)
    end

    it 'returns JSON error in robot mode' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_REQUEST')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el create/).to_stdout
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
