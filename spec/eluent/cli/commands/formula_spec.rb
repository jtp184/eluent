# frozen_string_literal: true

require 'eluent/cli/application'
require 'eluent/cli/commands/formula'

RSpec.describe Eluent::CLI::Commands::Formula do
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
  rescue Eluent::Formulas::FormulaNotFoundError,
         Eluent::Formulas::ParseError,
         Eluent::Formulas::VariableError,
         Eluent::Compaction::CompactionError,
         Eluent::Compaction::RestoreError,
         Eluent::Registry::IdNotFoundError,
         Eluent::Storage::RepositoryNotFoundError => e
    $stderr.puts "Error: #{e.message}"
    1
  end

  describe 'list action' do
    before do
      write_formula('test-workflow', <<~YAML)
        id: test-workflow
        title: Test Workflow
        steps:
          - id: step1
            title: Step 1
      YAML
    end

    it 'lists available formulas' do
      expect { run_command('list') }.to output(/test-workflow/).to_stdout
    end

    it 'returns 0 on success' do
      expect(run_command('list')).to eq(0)
    end

    context 'with robot mode' do
      it 'outputs JSON' do
        cmd = described_class.new(['list'], robot_mode: true)
        expect { cmd.run }.to output(/{"status":"ok"/).to_stdout
      end
    end
  end

  describe 'show action' do
    before do
      write_formula('test-workflow', <<~YAML)
        id: test-workflow
        title: Test Workflow
        description: A test workflow
        variables:
          name:
            required: true
        steps:
          - id: step1
            title: Step {{name}}
      YAML
    end

    it 'shows formula details' do
      expect { run_command('show', 'test-workflow') }
        .to output(/Test Workflow/).to_stdout
    end

    it 'shows variables' do
      expect { run_command('show', 'test-workflow') }
        .to output(/Variables/).to_stdout
    end

    it 'shows steps' do
      expect { run_command('show', 'test-workflow') }
        .to output(/Steps/).to_stdout
    end

    it 'returns error for missing ID' do
      expect(run_command('show')).to eq(1)
    end

    it 'returns error for unknown formula' do
      expect(run_command('show', 'nonexistent')).to eq(1)
    end
  end

  describe 'instantiate action' do
    before do
      write_formula('simple-workflow', <<~YAML)
        id: simple-workflow
        title: Simple {{name}}
        variables:
          name:
            required: true
        steps:
          - id: design
            title: Design {{name}}
          - id: implement
            title: Implement {{name}}
            depends_on:
              - design
      YAML
    end

    it 'creates atoms from formula' do
      expect { run_command('instantiate', 'simple-workflow', '--var', 'name=Auth') }
        .to output(/Created 3 items/).to_stdout
    end

    it 'returns 0 on success' do
      expect(run_command('instantiate', 'simple-workflow', '--var', 'name=Auth')).to eq(0)
    end

    it 'returns error for missing variables' do
      expect(run_command('instantiate', 'simple-workflow')).to eq(1)
    end
  end

  describe 'distill action' do
    # Use valid ULID-format IDs
    let(:root_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CPKR' }
    let(:child_id) { 'testrepo-01KFBX0000E0MK5JSH2N34CPLR' }

    before do
      now = Time.now.utc.iso8601
      # Write full data file with atoms
      File.write(
        File.join(root_path, '.eluent', 'data.jsonl'),
        <<~JSONL
          {"_type":"header","repo_name":"testrepo"}
          {"_type":"atom","id":"#{root_id}","title":"Feature X","issue_type":"epic","status":"open","created_at":"#{now}","updated_at":"#{now}"}
          {"_type":"atom","id":"#{child_id}","title":"Design X","parent_id":"#{root_id}","status":"open","created_at":"#{now}","updated_at":"#{now}"}
        JSONL
      )
    end

    it 'extracts formula from work hierarchy' do
      expect { run_command('distill', root_id, '--id', 'x-workflow') }
        .to output(/Extracted formula/).to_stdout
    end

    it 'creates formula file' do
      run_command('distill', root_id, '--id', 'x-workflow')
      expect(File.exist?(File.join(root_path, '.eluent', 'formulas', 'x-workflow.yaml'))).to be true
    end

    it 'returns error for missing --id' do
      expect(run_command('distill', root_id)).to eq(1)
    end
  end

  describe 'compose action' do
    before do
      write_formula('design', <<~YAML)
        id: design
        title: Design
        steps:
          - id: step1
            title: Design Step
      YAML

      write_formula('implement', <<~YAML)
        id: implement
        title: Implement
        steps:
          - id: step1
            title: Implement Step
      YAML
    end

    it 'combines formulas' do
      expect { run_command('compose', 'design', 'implement', '--id', 'combined') }
        .to output(/Created composite formula/).to_stdout
    end

    it 'creates combined formula file' do
      run_command('compose', 'design', 'implement', '--id', 'combined')
      expect(File.exist?(File.join(root_path, '.eluent', 'formulas', 'combined.yaml'))).to be true
    end

    it 'returns error for missing --id' do
      expect(run_command('compose', 'design', 'implement')).to eq(1)
    end

    it 'returns error for fewer than 2 formulas' do
      expect(run_command('compose', 'design', '--id', 'single')).to eq(1)
    end
  end

  describe 'compact action' do
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
      expect { run_command('compact', '--tier', '1') }
        .to output(/Compaction Complete/).to_stdout
    end

    context 'with --preview flag' do
      it 'shows preview without compacting' do
        expect { run_command('compact', '--tier', '1', '--preview') }
          .to output(/Preview/).to_stdout
      end
    end

    it 'returns error for invalid tier' do
      expect(run_command('compact', '--tier', '99')).to eq(1)
    end
  end

  describe 'invalid action' do
    it 'returns error for unknown action' do
      expect(run_command('unknown')).to eq(1)
    end
  end

  describe 'help' do
    it 'shows help text' do
      expect { run_command('--help') }.to output(/formula/).to_stdout
    end
  end

  private

  def write_formula(id, content)
    File.write(File.join(root_path, '.eluent', 'formulas', "#{id}.yaml"), content)
  end
end
