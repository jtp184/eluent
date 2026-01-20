# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/discard'

RSpec.describe Eluent::CLI::Commands::Discard do
  let(:root_path) { Dir.mktmpdir }
  let(:atom_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP0A' }
  let(:now) { Time.now.utc.iso8601 }
  let(:old_time) { (Time.now.utc - (60 * 24 * 60 * 60)).iso8601 } # 60 days ago

  before do
    FileUtils.mkdir_p(File.join(root_path, '.eluent', 'formulas'))
    File.write(File.join(root_path, '.eluent', 'config.yaml'), YAML.dump('repo_name' => 'testrepo'))
    File.write(
      File.join(root_path, '.eluent', 'data.jsonl'),
      <<~JSONL
        {"_type":"header","repo_name":"testrepo"}
        {"_type":"atom","id":"#{atom_id}","title":"Open Task","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
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

  describe 'discarding an item (default action)' do
    it 'sets status to discard' do
      run_command(atom_id)

      data = read_atom_from_file
      expect(data['status']).to eq('discard')
    end

    it 'returns 0 on success' do
      expect(run_command(atom_id, robot_mode: true)).to eq(0)
    end

    it 'returns error if already discarded' do
      # Discard first
      run_command(atom_id)

      # Try to discard again
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('ALREADY_DISCARDED')
    end

    it 'returns NOT_FOUND for unknown atom' do
      output = capture_stdout { run_command('nonexistent', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'list action' do
    before do
      # Add a discarded atom
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'atom',
                               id: 'testrepo-01KFBX0000E0MK5JSH2N34CP0B',
                               title: 'Discarded Item',
                               status: 'discard',
                               issue_type: 'task',
                               priority: 2,
                               labels: [],
                               created_at: now,
                               updated_at: now
                             }))
      end
    end

    it 'shows discarded items' do
      output = capture_stdout { run_command('list', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['count']).to eq(1)
      expect(parsed['data']['items'].first['title']).to eq('Discarded Item')
    end

    it 'returns 0' do
      expect(run_command('list', robot_mode: true)).to eq(0)
    end
  end

  describe 'restore action' do
    before do
      # Make atom discarded
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"Discarded Task","status":"discard","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'restores to open status' do
      run_command('restore', atom_id)

      data = read_atom_from_file
      expect(data['status']).to eq('open')
    end

    it 'returns 0 on success' do
      expect(run_command('restore', atom_id, robot_mode: true)).to eq(0)
    end

    it 'returns error if not discarded' do
      # Restore first
      run_command('restore', atom_id)

      # Try to restore again
      output = capture_stdout { run_command('restore', atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_DISCARDED')
    end

    it 'returns error when ID missing' do
      output = capture_stdout { run_command('restore', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('MISSING_ID')
    end
  end

  describe 'prune action' do
    before do
      # Add old discarded atoms
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'atom',
                               id: 'testrepo-01KFBX0000E0MK5JSH2N34CP0B',
                               title: 'Old Discarded Item',
                               status: 'discard',
                               issue_type: 'task',
                               priority: 2,
                               labels: [],
                               created_at: old_time,
                               updated_at: old_time
                             }))
      end
    end

    it 'deletes old discards with --force' do
      output = capture_stdout { run_command('prune', '--days', '30', '--force', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['pruned_count']).to eq(1)
    end

    it 'returns 0 when nothing to prune' do
      # Prune first to clear
      run_command('prune', '--days', '30', '--force', robot_mode: true)

      output = capture_stdout { run_command('prune', '--days', '30', '--force', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
    end
  end

  describe 'robot mode' do
    it 'outputs JSON for discard' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['status']).to eq('discard')
    end

    it 'outputs JSON for list' do
      output = capture_stdout { run_command('list', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['items']).to be_an(Array)
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el discard/).to_stdout
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
