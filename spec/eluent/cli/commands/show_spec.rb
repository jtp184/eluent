# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/show'

RSpec.describe Eluent::CLI::Commands::Show do
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
        {"_type":"atom","id":"#{atom_id}","title":"Test Item","status":"open","issue_type":"task","priority":1,"assignee":"alice","labels":["auth","urgent"],"description":"A test description","created_at":"#{now}","updated_at":"#{now}"}
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

  describe 'showing an atom' do
    it 'displays atom by full ID' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['title']).to eq('Test Item')
    end

    it 'displays atom by short ID' do
      # Short ID is based on the randomness portion of the ULID (E0MK5JSH2N34CP0A)
      # Minimum prefix is 4 characters from that
      short_id = 'E0MK'
      output = capture_stdout { run_command(short_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['title']).to eq('Test Item')
    end

    it 'shows title' do
      expect { run_command(atom_id) }.to output(/Test Item/).to_stdout
    end

    it 'shows status' do
      expect { run_command(atom_id) }.to output(/open/i).to_stdout
    end

    it 'shows priority' do
      expect { run_command(atom_id) }.to output(/1/).to_stdout
    end

    it 'shows assignee' do
      expect { run_command(atom_id) }.to output(/alice/).to_stdout
    end

    it 'shows labels' do
      output = capture_stdout { run_command(atom_id) }
      expect(output).to include('auth')
      expect(output).to include('urgent')
    end

    it 'shows description' do
      expect { run_command(atom_id) }.to output(/A test description/).to_stdout
    end

    it 'returns 0 on success' do
      expect(run_command(atom_id)).to eq(0)
    end
  end

  describe '--verbose flag' do
    it 'shows full ID' do
      expect { run_command(atom_id, '--verbose') }.to output(/#{atom_id}/).to_stdout
    end

    it 'shows timestamps' do
      expect { run_command(atom_id, '--verbose') }.to output(/Created/i).to_stdout
    end
  end

  describe '--comments flag' do
    let(:comment_id) { "#{atom_id}-c1" }

    before do
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'comment',
                               id: comment_id,
                               parent_id: atom_id,
                               author: 'bob',
                               content: 'This is a comment',
                               created_at: now
                             }))
      end
    end

    it 'shows comments' do
      output = capture_stdout { run_command(atom_id, '--comments') }
      expect(output).to include('bob')
      expect(output).to include('This is a comment')
    end
  end

  describe '--deps flag' do
    let(:dep_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP0B' }

    before do
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'atom',
                               id: dep_id,
                               title: 'Dependency Item',
                               status: 'open',
                               issue_type: 'task',
                               priority: 2,
                               labels: [],
                               created_at: now,
                               updated_at: now
                             }))
        f.puts(JSON.generate({
                               _type: 'bond',
                               source_id: atom_id,
                               target_id: dep_id,
                               dependency_type: 'blocks'
                             }))
      end
    end

    it 'shows dependencies' do
      output = capture_stdout { run_command(atom_id, '--deps') }
      expect(output).to match(/Dependencies|Depends on|Depended on/i)
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
    it 'outputs JSON' do
      output = capture_stdout { run_command(atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['title']).to eq('Test Item')
      expect(parsed['data']['id']).to eq(atom_id)
    end

    it 'includes comments in JSON when --comments' do
      # Add a comment first
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'comment',
                               id: "#{atom_id}-c1",
                               parent_id: atom_id,
                               author: 'bob',
                               content: 'Test comment',
                               created_at: now
                             }))
      end

      output = capture_stdout { run_command(atom_id, '--comments', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['comments']).to be_an(Array)
    end

    it 'includes dependencies in JSON when --deps' do
      output = capture_stdout { run_command(atom_id, '--deps', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['data']['dependencies']).to be_a(Hash)
      expect(parsed['data']['dependencies']['outgoing']).to be_an(Array)
      expect(parsed['data']['dependencies']['incoming']).to be_an(Array)
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el show/).to_stdout
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
