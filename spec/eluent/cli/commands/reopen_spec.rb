# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/reopen'

RSpec.describe Eluent::CLI::Commands::Reopen do
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
        {"_type":"atom","id":"#{atom_id}","title":"Closed Task","status":"closed","issue_type":"task","priority":2,"labels":[],"close_reason":"Done","created_at":"#{now}","updated_at":"#{now}"}
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

  describe 'reopening a closed atom' do
    it 'sets status to open' do
      run_command(atom_id)

      data = read_atom_from_file
      expect(data['status']).to eq('open')
    end

    it 'clears close_reason' do
      run_command(atom_id)

      data = read_atom_from_file
      expect(data['close_reason']).to be_nil
    end

    it 'returns 0 on success' do
      expect(run_command(atom_id, robot_mode: true)).to eq(0)
    end

    it 'outputs success message' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
    end
  end

  describe 'reopening a discarded atom' do
    before do
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"Discarded Task","status":"discard","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'sets status to open' do
      run_command(atom_id)

      data = read_atom_from_file
      expect(data['status']).to eq('open')
    end
  end

  describe 'CONFLICT error' do
    before do
      # Make atom already open
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{atom_id}","title":"Open Task","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'returns error if not closed' do
      expect(run_command(atom_id, robot_mode: true)).to eq(1)
    end

    it 'outputs conflict error' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('CONFLICT')
    end
  end

  describe 'NOT_FOUND error' do
    it 'returns error for unknown ID' do
      expect(run_command('nonexistent', robot_mode: true)).to eq(1)
    end

    it 'outputs error message' do
      output = capture_stdout { run_command('nonexistent', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'robot mode' do
    it 'outputs JSON with atom data' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['status']).to eq('open')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el reopen/).to_stdout
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
