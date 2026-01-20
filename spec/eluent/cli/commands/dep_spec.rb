# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/dep'

RSpec.describe Eluent::CLI::Commands::Dep do
  let(:root_path) { Dir.mktmpdir }
  let(:atom1_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP01' }
  let(:atom2_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP02' }
  let(:atom3_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP03' }
  let(:now) { Time.now.utc.iso8601 }

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      <<~JSONL
        {"_type":"header","repo_name":"testrepo"}
        {"_type":"atom","id":"#{atom1_id}","title":"Task A","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        {"_type":"atom","id":"#{atom2_id}","title":"Task B","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        {"_type":"atom","id":"#{atom3_id}","title":"Task C","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
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
         Eluent::Registry::IdNotFoundError,
         Eluent::Graph::CycleDetectedError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'add action' do
    it 'creates dependency' do
      run_command('add', atom1_id, atom2_id)

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      bond_line = data_lines.find { |line| line.include?('"_type":"bond"') }
      expect(bond_line).not_to be_nil

      bond = JSON.parse(bond_line)
      expect(bond['source_id']).to eq(atom1_id)
      expect(bond['target_id']).to eq(atom2_id)
      expect(bond['dependency_type']).to eq('blocks')
    end

    it 'returns 0 on success' do
      expect(run_command('add', atom1_id, atom2_id, robot_mode: true)).to eq(0)
    end

    it 'supports --type option' do
      run_command('add', atom1_id, atom2_id, '--type', 'waits_for')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      bond_line = data_lines.find { |line| line.include?('"_type":"bond"') }
      bond = JSON.parse(bond_line)

      expect(bond['dependency_type']).to eq('waits_for')
    end

    it 'validates cycles' do
      # Create A -> B
      run_command('add', atom1_id, atom2_id)

      # Create B -> C
      run_command('add', atom2_id, atom3_id)

      # Try to create C -> A (would create cycle)
      output = capture_stdout { run_command('add', atom3_id, atom1_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('CYCLE_DETECTED')
    end

    it 'returns error for missing args' do
      output = capture_stdout { run_command('add', atom1_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('MISSING_ARGS')
    end

    it 'returns NOT_FOUND for unknown source' do
      output = capture_stdout { run_command('add', 'nonexistent', atom2_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'remove action' do
    before do
      # Create a bond directly in the file
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom1_id,
                               target_id: atom2_id,
                               dependency_type: 'blocks'
                             }))
      end
    end

    it 'returns success response' do
      output = capture_stdout { run_command('remove', atom1_id, atom2_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['source_id']).to eq(atom1_id)
      expect(parsed['data']['target_id']).to eq(atom2_id)
    end

    it 'returns 0 on success' do
      expect(run_command('remove', atom1_id, atom2_id, robot_mode: true)).to eq(0)
    end
  end

  describe 'list action' do
    before do
      # Create bonds: A blocks B, C blocks A
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom1_id,
                               target_id: atom2_id,
                               dependency_type: 'blocks'
                             }))
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom3_id,
                               target_id: atom1_id,
                               dependency_type: 'blocks'
                             }))
      end
    end

    it 'shows in/out dependencies' do
      output = capture_stdout { run_command('list', atom1_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['outgoing']).to be_an(Array)
      expect(parsed['data']['incoming']).to be_an(Array)
      expect(parsed['data']['outgoing'].size).to eq(1)
      expect(parsed['data']['incoming'].size).to eq(1)
    end

    it 'returns 0 on success' do
      expect(run_command('list', atom1_id, robot_mode: true)).to eq(0)
    end

    it 'returns error when ID missing' do
      output = capture_stdout { run_command('list', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('MISSING_ID')
    end
  end

  describe 'tree action' do
    before do
      # Create chain: A blocks B, B blocks C
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom1_id,
                               target_id: atom2_id,
                               dependency_type: 'blocks'
                             }))
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom2_id,
                               target_id: atom3_id,
                               dependency_type: 'blocks'
                             }))
      end
    end

    it 'renders dependency tree' do
      output = capture_stdout { run_command('tree', atom1_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['descendants']).to be_an(Array)
      expect(parsed['data']['ancestors']).to be_an(Array)
    end

    it 'supports --blocking-only flag' do
      output = capture_stdout { run_command('tree', atom1_id, '--blocking-only', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
    end

    it 'returns 0 on success' do
      expect(run_command('tree', atom1_id, robot_mode: true)).to eq(0)
    end
  end

  describe 'check action' do
    it 'reports healthy graph' do
      output = capture_stdout { run_command('check', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['issues_count']).to eq(0)
    end

    it 'reports orphan bonds' do
      # Create bond to nonexistent atom
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom1_id,
                               target_id: 'testrepo-01KFBX0000E0MK5JSH2N34CPZZ',
                               dependency_type: 'blocks'
                             }))
      end

      output = capture_stdout { run_command('check', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('warning')
      expect(parsed['data']['issues_count']).to be > 0
      expect(parsed['data']['issues'].first['type']).to eq('orphan_bond')
    end

    it 'returns 0 when healthy' do
      expect(run_command('check', robot_mode: true)).to eq(0)
    end

    it 'returns 1 when issues found' do
      # Create orphan bond
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom1_id,
                               target_id: 'testrepo-01KFBX0000E0MK5JSH2N34CPZZ',
                               dependency_type: 'blocks'
                             }))
      end

      expect(run_command('check', robot_mode: true)).to eq(1)
    end
  end

  describe 'invalid action' do
    it 'returns error for unknown action' do
      output = capture_stdout { run_command('unknown', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_ACTION')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el dep/).to_stdout
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
