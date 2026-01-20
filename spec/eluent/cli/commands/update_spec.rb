# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/update'

RSpec.describe Eluent::CLI::Commands::Update do
  let(:root_path) { Dir.mktmpdir }
  let(:atom_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP0A' }
  let(:now) { Time.now.utc.iso8601 }

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      <<~JSONL
        {"_type":"header","repo_name":"testrepo"}
        {"_type":"atom","id":"#{atom_id}","title":"Original Title","status":"open","issue_type":"task","priority":2,"assignee":"alice","labels":["auth"],"description":"Original description","created_at":"#{now}","updated_at":"#{now}"}
      JSONL
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

  describe 'updating fields' do
    it 'updates --title' do
      run_command(atom_id, '--title', 'Updated Title')

      data = read_atom_from_file
      expect(data['title']).to eq('Updated Title')
    end

    it 'updates --description' do
      run_command(atom_id, '--description', 'New description')

      data = read_atom_from_file
      expect(data['description']).to eq('New description')
    end

    it 'updates --type' do
      run_command(atom_id, '--type', 'bug')

      data = read_atom_from_file
      expect(data['issue_type']).to eq('bug')
    end

    it 'updates --priority' do
      run_command(atom_id, '--priority', '0')

      data = read_atom_from_file
      expect(data['priority']).to eq(0)
    end

    it 'updates --assignee' do
      run_command(atom_id, '--assignee', 'bob')

      data = read_atom_from_file
      expect(data['assignee']).to eq('bob')
    end

    it 'updates --status' do
      run_command(atom_id, '--status', 'in_progress')

      data = read_atom_from_file
      expect(data['status']).to eq('in_progress')
    end

    it 'returns 0 on success' do
      expect(run_command(atom_id, '--title', 'New Title', robot_mode: true)).to eq(0)
    end
  end

  describe 'label management' do
    it 'adds --label' do
      run_command(atom_id, '--label', 'security')

      data = read_atom_from_file
      expect(data['labels']).to include('auth', 'security')
    end

    it 'removes --remove-label' do
      run_command(atom_id, '--remove-label', 'auth')

      data = read_atom_from_file
      expect(data['labels']).not_to include('auth')
    end
  end

  describe '--clear-assignee flag' do
    it 'removes assignee' do
      run_command(atom_id, '--clear-assignee')

      data = read_atom_from_file
      expect(data['assignee']).to be_nil
    end
  end

  describe '--defer-until option' do
    it 'sets defer date' do
      run_command(atom_id, '--defer-until', '2025-12-31')

      data = read_atom_from_file
      expect(data['defer_until']).to include('2025-12-31')
    end
  end

  describe '--persist flag' do
    before do
      # Create ephemeral atom
      ephemeral_path = File.join(root_path, '.eluent', 'ephemeral.jsonl')
      File.write(ephemeral_path, "{\"_type\":\"header\",\"repo_name\":\"testrepo\"}\n")
      File.open(ephemeral_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'atom',
                               id: 'testrepo-01KFBX0000E0MK5JSH2N34CPEP',
                               title: 'Ephemeral Task',
                               status: 'open',
                               issue_type: 'task',
                               priority: 2,
                               labels: [],
                               created_at: now,
                               updated_at: now
                             }))
      end
    end

    it 'converts ephemeral to persistent' do
      run_command('testrepo-01KFBX0000E0MK5JSH2N34CPEP', '--persist')

      # Check that atom now exists in main data file
      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      ephemeral_in_data = data_lines.any? { |line| line.include?('01KFBX0000E0MK5JSH2N34CPEP') }
      expect(ephemeral_in_data).to be true
    end
  end

  describe 'NOT_FOUND error' do
    it 'returns error for unknown ID' do
      expect(run_command('nonexistent', '--title', 'New', robot_mode: true)).to eq(1)
    end

    it 'outputs error message' do
      output = capture_stdout { run_command('nonexistent', '--title', 'New', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'no changes error' do
    it 'returns error when no changes specified' do
      expect(run_command(atom_id, robot_mode: true)).to eq(1)
    end

    it 'outputs error message' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_REQUEST')
    end
  end

  describe 'robot mode' do
    it 'outputs JSON with changes' do
      output = capture_stdout { run_command(atom_id, '--title', 'New Title', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['changes']['title']).to eq('New Title')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el update/).to_stdout
    end

    it 'returns 0' do
      expect(run_command('--help')).to eq(0)
    end
  end

  private

  def read_atom_from_file
    data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
    atom_line = data_lines.reverse.find { |line| line.include?(atom_id) }
    JSON.parse(atom_line)
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
