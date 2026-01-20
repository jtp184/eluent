# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/compact'

RSpec.describe Eluent::CLI::Commands::Compact do
  let(:root_path) { Dir.mktmpdir }

  before do
    # Create .eluent structure with all necessary files
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

  def run_command(*args)
    described_class.new(args).run
  rescue Eluent::Compaction::CompactionError,
         Eluent::Compaction::RestoreError,
         Eluent::Registry::IdNotFoundError,
         Eluent::Storage::RepositoryNotFoundError => e
    warn "Error: #{e.message}"
    1
  end

  describe 'run action' do
    # Use valid ULID-format ID
    let(:old_atom_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CP0D' }

    before do
      old_time = (Time.now.utc - (60 * 24 * 60 * 60)).iso8601
      # Write full data file with old atom
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{old_atom_id}","title":"Old Item","status":"closed","created_at":"#{old_time}","updated_at":"#{old_time}","description":"#{'x' * 100}"}
        JSONL
      )
    end

    it 'compacts old items' do
      expect { run_command('run', '--tier', '1') }
        .to output(/Compaction Complete/).to_stdout
    end

    it 'uses run action by default' do
      expect { run_command('--tier', '1') }
        .to output(/Compaction Complete/).to_stdout
    end

    context 'with --preview flag' do
      it 'shows preview without compacting' do
        expect { run_command('run', '--tier', '1', '--preview') }
          .to output(/Preview/).to_stdout
      end
    end

    it 'returns error for invalid tier' do
      expect(run_command('run', '--tier', '99')).to eq(1)
    end
  end

  describe 'restore action' do
    it 'returns error when atom not found' do
      expect(run_command('restore', 'nonexistent')).to eq(1)
    end
  end

  describe 'invalid action' do
    it 'returns error for unknown action' do
      expect(run_command('unknown')).to eq(1)
    end
  end

  describe 'help' do
    it 'shows help text' do
      expect { run_command('--help') }.to output(/compact/).to_stdout
    end
  end
end
