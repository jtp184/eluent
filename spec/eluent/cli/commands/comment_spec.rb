# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/comment'

RSpec.describe Eluent::CLI::Commands::Comment do
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
        {"_type":"atom","id":"#{atom_id}","title":"Test Task","status":"open","issue_type":"task","priority":2,"labels":[],"created_at":"#{now}","updated_at":"#{now}"}
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

  describe 'add action' do
    it 'adds comment with content and author' do
      run_command('add', atom_id, 'This is a comment', '--author', 'bob@example.com')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      comment_line = data_lines.find { |line| line.include?('"_type":"comment"') }
      expect(comment_line).not_to be_nil

      comment = JSON.parse(comment_line)
      expect(comment['content']).to eq('This is a comment')
      expect(comment['author']).to eq('bob@example.com')
      expect(comment['parent_id']).to eq(atom_id)
    end

    it 'returns 0 on success' do
      expect(run_command('add', atom_id, 'Comment', '--author', 'user', robot_mode: true)).to eq(0)
    end

    it 'uses default author when not specified' do
      run_command('add', atom_id, 'Comment without author')

      data_lines = File.readlines(File.join(root_path, '.eluent', 'data.jsonl'))
      comment_line = data_lines.find { |line| line.include?('"_type":"comment"') }
      comment = JSON.parse(comment_line)

      expect(comment['author']).not_to be_nil
      expect(comment['author']).not_to be_empty
    end

    it 'returns error when content missing' do
      expect(run_command('add', atom_id, robot_mode: true)).to eq(1)
    end

    it 'outputs error when content missing' do
      output = capture_stdout { run_command('add', atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('MISSING_CONTENT')
    end

    it 'returns NOT_FOUND for unknown atom' do
      output = capture_stdout { run_command('add', 'nonexistent', 'Comment', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'list action' do
    before do
      # Add some comments
      data_path = File.join(root_path, '.eluent', 'data.jsonl')
      File.open(data_path, 'a') do |f|
        f.puts(JSON.generate({
                               _type: 'comment',
                               id: "#{atom_id}-c1",
                               parent_id: atom_id,
                               author: 'alice',
                               content: 'First comment',
                               created_at: now
                             }))
        f.puts(JSON.generate({
                               _type: 'comment',
                               id: "#{atom_id}-c2",
                               parent_id: atom_id,
                               author: 'bob',
                               content: 'Second comment',
                               created_at: now
                             }))
      end
    end

    it 'lists comments for atom' do
      output = capture_stdout { run_command('list', atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['count']).to eq(2)
      expect(parsed['data']['comments'].map { |c| c['content'] }).to include('First comment', 'Second comment')
    end

    it 'returns 0 on success' do
      expect(run_command('list', atom_id, robot_mode: true)).to eq(0)
    end

    it 'returns NOT_FOUND for unknown atom' do
      output = capture_stdout { run_command('list', 'nonexistent', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('NOT_FOUND')
    end
  end

  describe 'robot mode' do
    it 'outputs JSON for add' do
      output = capture_stdout { run_command('add', atom_id, 'Test comment', '--author', 'test', robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['content']).to eq('Test comment')
    end

    it 'outputs JSON for list' do
      output = capture_stdout { run_command('list', atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('ok')
      expect(parsed['data']['comments']).to be_an(Array)
    end
  end

  describe 'invalid action' do
    it 'returns error for unknown action' do
      output = capture_stdout { run_command('unknown', atom_id, robot_mode: true) }
      parsed = JSON.parse(output)

      expect(parsed['status']).to eq('error')
      expect(parsed['error']['code']).to eq('INVALID_ACTION')
    end
  end

  describe '--help' do
    it 'shows usage' do
      expect { run_command('--help') }.to output(/el comment/).to_stdout
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
