# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/ready'

RSpec.describe Eluent::CLI::Commands::Ready do
  let(:root_path) { Dir.mktmpdir }
  let(:atom1_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP01' }
  let(:atom2_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP02' }
  let(:atom3_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP03' }
  let(:now) { Time.now.utc.iso8601 }
  let(:older) { (Time.now.utc - 86_400).iso8601 }

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
    defaults = {
      _type: 'atom',
      id: "testrepo-01KFBX0000E0MK5JSH2N34CP#{rand(10..99)}",
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

  def create_bond(source_id:, target_id:, dependency_type: 'blocks')
    bond = {
      _type: 'bond',
      source_id: source_id,
      target_id: target_id,
      dependency_type: dependency_type
    }
    data_path = File.join(root_path, '.eluent', 'data.jsonl')
    File.open(data_path, 'a') { |f| f.puts(JSON.generate(bond)) }
    bond
  end

  describe 'showing ready items' do
    before do
      create_atom(id: atom1_id, title: 'Ready Task', priority: 1)
      create_atom(id: atom2_id, title: 'Closed Task', status: 'closed')
    end

    it 'shows only unblocked, open items' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Ready Task')
      expect(titles).not_to include('Closed Task')
    end

    it 'returns 0' do
      expect(run_command(robot_mode: true)).to eq(0)
    end
  end

  describe 'excluding blocked items' do
    before do
      create_atom(id: atom1_id, title: 'Blocker Task')
      create_atom(id: atom2_id, title: 'Blocked Task')
      create_bond(source_id: atom1_id, target_id: atom2_id)
    end

    it 'excludes blocked items' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Blocker Task')
      expect(titles).not_to include('Blocked Task')
    end
  end

  describe 'excluding abstract types' do
    before do
      create_atom(id: atom1_id, title: 'Regular Task', issue_type: 'task')
      create_atom(id: atom2_id, title: 'Epic Item', issue_type: 'epic')
    end

    it 'excludes epic by default' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Regular Task')
      expect(titles).not_to include('Epic Item')
    end

    it 'includes abstract types with --include-abstract' do
      output = capture_stdout { run_command('--include-abstract', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Epic Item')
    end
  end

  describe '--sort option' do
    before do
      create_atom(id: atom1_id, title: 'Low Priority', priority: 3, created_at: older)
      create_atom(id: atom2_id, title: 'High Priority', priority: 1, created_at: now)
    end

    it 'sorts by priority by default' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      items = parsed['data']['items']
      expect(items.first['title']).to eq('High Priority')
    end

    it 'sorts by oldest with --sort oldest' do
      output = capture_stdout { run_command('--sort', 'oldest', robot_mode: true) }
      parsed = JSON.parse(output)

      items = parsed['data']['items']
      expect(items.first['title']).to eq('Low Priority')
    end
  end

  describe 'filters' do
    before do
      create_atom(id: atom1_id, title: 'Bug Task', issue_type: 'bug', assignee: 'alice', labels: ['urgent'],
                  priority: 0)
      create_atom(id: atom2_id, title: 'Feature Task', issue_type: 'feature', assignee: 'bob', labels: ['backend'],
                  priority: 2)
    end

    it 'filters by --type' do
      output = capture_stdout { run_command('--type', 'bug', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Bug Task')
      expect(titles).not_to include('Feature Task')
    end

    it 'filters by --exclude-type' do
      output = capture_stdout { run_command('--exclude-type', 'bug', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).not_to include('Bug Task')
      expect(titles).to include('Feature Task')
    end

    it 'filters by --assignee' do
      output = capture_stdout { run_command('--assignee', 'alice', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Bug Task')
      expect(titles).not_to include('Feature Task')
    end

    it 'filters by --label' do
      output = capture_stdout { run_command('--label', 'urgent', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Bug Task')
      expect(titles).not_to include('Feature Task')
    end

    it 'filters by --priority' do
      output = capture_stdout { run_command('--priority', '0', robot_mode: true) }
      parsed = JSON.parse(output)

      titles = parsed['data']['items'].map { |i| i['title'] }
      expect(titles).to include('Bug Task')
      expect(titles).not_to include('Feature Task')
    end
  end

  describe 'robot mode' do
    before do
      create_atom(title: 'Task 1')
      create_atom(title: 'Task 2')
    end

    it 'outputs JSON' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['count']).to eq(2)
      expect(parsed['data']['items']).to be_an(Array)
    end
  end

  describe 'empty results' do
    it 'returns empty array when no ready items' do
      output = capture_stdout { run_command(robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['count']).to eq(0)
      expect(parsed['data']['items']).to eq([])
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el ready/).to_stdout
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
