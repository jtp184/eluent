# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/list'

RSpec.describe Eluent::CLI::Commands::List do
  let(:root_path) { Dir.mktmpdir }
  let(:atom_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP0A' }
  let(:now) { Time.now.utc.iso8601 }
  let(:atom_counter) { { value: 0 } }

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
  rescue Eluent::Storage::RepositoryNotFoundError => e
    warn "Error: #{e.message}"
    1
  end

  def create_atom(attrs = {})
    atom_counter[:value] += 1

    defaults = {
      _type: 'atom',
      id: "testrepo-01KFBX0000E0MK5JSH2N34CP#{atom_counter[:value].to_s.rjust(3, '0')}",
      title: 'Test Item',
      status: 'open',
      issue_type: 'task',
      priority: 2,
      labels: [],
      created_at: now,
      updated_at: now
    }

    atom = defaults.merge(attrs)
    data_path = File.join(root_path, '.eluent', 'data.jsonl')
    File.open(data_path, 'a') { |f| f.puts(JSON.generate(atom)) }
    atom
  end

  describe 'listing items' do
    it 'lists open items by default' do
      create_atom(title: 'Open Task', status: 'open')
      create_atom(title: 'Closed Task', status: 'closed')

      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Open Task')
      expect(titles).not_to include('Closed Task')
    end

    it 'returns 0' do
      expect(run_command(robot_mode: true)).to eq(0)
    end
  end

  describe '--all flag' do
    it 'includes closed items' do
      create_atom(title: 'Open Task', status: 'open')
      create_atom(title: 'Closed Task', status: 'closed')

      output = capture_stdout { run_command('--all', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Open Task')
      expect(titles).to include('Closed Task')
    end
  end

  describe '--status filter' do
    before do
      create_atom(title: 'Open Task', status: 'open')
      create_atom(title: 'In Progress', status: 'in_progress')
      create_atom(title: 'Closed Task', status: 'closed')
    end

    it 'filters by status' do
      output = capture_stdout { run_command('--status', 'closed', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Closed Task')
      expect(titles).not_to include('Open Task')
    end

    it 'shows in_progress status' do
      output = capture_stdout { run_command('--status', 'in_progress', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('In Progress')
    end
  end

  describe '--type filter' do
    before do
      create_atom(title: 'Bug Report', issue_type: 'bug')
      create_atom(title: 'Feature Request', issue_type: 'feature')
    end

    it 'filters by type' do
      output = capture_stdout { run_command('--type', 'bug', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Bug Report')
      expect(titles).not_to include('Feature Request')
    end
  end

  describe '--assignee filter' do
    before do
      create_atom(title: 'Alice Task', assignee: 'alice')
      create_atom(title: 'Bob Task', assignee: 'bob')
    end

    it 'filters by assignee' do
      output = capture_stdout { run_command('--assignee', 'alice', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Alice Task')
      expect(titles).not_to include('Bob Task')
    end
  end

  describe '--label filter' do
    before do
      create_atom(title: 'Auth Task', labels: %w[auth security])
      create_atom(title: 'UI Task', labels: ['frontend'])
    end

    it 'filters by label' do
      output = capture_stdout { run_command('--label', 'auth', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Auth Task')
      expect(titles).not_to include('UI Task')
    end
  end

  describe '--priority filter' do
    before do
      create_atom(title: 'Critical Task', priority: 0)
      create_atom(title: 'Normal Task', priority: 2)
    end

    it 'filters by priority' do
      output = capture_stdout { run_command('--priority', '0', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Critical Task')
      expect(titles).not_to include('Normal Task')
    end
  end

  describe '--include-discarded flag' do
    before do
      create_atom(title: 'Active Task', status: 'open')
      create_atom(title: 'Discarded Task', status: 'discard')
    end

    it 'includes discarded items' do
      output = capture_stdout { run_command('--include-discarded', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Discarded Task')
    end

    it 'excludes discarded by default' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).not_to include('Discarded Task')
    end
  end

  describe '--ephemeral flag' do
    before do
      create_atom(title: 'Regular Task')

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

    it 'shows only ephemeral items' do
      output = capture_stdout { run_command('--ephemeral', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Ephemeral Task')
    end
  end

  describe 'robot mode' do
    before do
      create_atom(title: 'Task 1')
      create_atom(title: 'Task 2')
    end

    it 'outputs JSON array' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['count']).to eq(2)
      expect(parsed['data']['items']).to be_an(Array)
      expect(parsed['data']['items'].size).to eq(2)
    end
  end

  describe 'empty repository' do
    it 'shows no items found message' do
      expect { run_command }.to output(/No items found/i).to_stdout
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el list/).to_stdout
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
