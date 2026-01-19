# frozen_string_literal: true

RSpec.describe Eluent::Formulas::Parser, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }
  let(:parser) { described_class.new(paths: paths) }

  before do
    setup_eluent_directory(root_path)
    FileUtils.mkdir_p(paths.formulas_dir)
  end

  describe '#parse' do
    context 'when formula file exists' do
      before do
        write_formula('test-workflow', <<~YAML)
          id: test-workflow
          title: "Test: {{name}}"
          description: A test workflow
          variables:
            name:
              required: true
              description: Feature name
            component:
              default: core
          steps:
            - id: design
              title: "Design {{name}}"
            - id: implement
              title: "Implement"
              depends_on:
                - design
        YAML
      end

      it 'parses formula from YAML file' do
        formula = parser.parse('test-workflow')
        expect(formula).to be_a(Eluent::Models::Formula)
        expect(formula.id).to eq('test-workflow')
      end

      it 'parses title and description' do
        formula = parser.parse('test-workflow')
        expect(formula.title).to eq('Test: {{name}}')
        expect(formula.description).to eq('A test workflow')
      end

      it 'parses variables' do
        formula = parser.parse('test-workflow')
        expect(formula.variables['name'].required?).to be true
        expect(formula.variables['component'].default).to eq('core')
      end

      it 'parses steps' do
        formula = parser.parse('test-workflow')
        expect(formula.steps.size).to eq(2)
        expect(formula.steps.first.id).to eq('design')
      end

      it 'parses step dependencies' do
        formula = parser.parse('test-workflow')
        implement_step = formula.step_by_id('implement')
        expect(implement_step.depends_on).to eq(['design'])
      end
    end

    context 'when formula file does not exist' do
      it 'raises FormulaNotFoundError' do
        expect { parser.parse('nonexistent') }
          .to raise_error(Eluent::Formulas::FormulaNotFoundError)
      end
    end

    context 'when YAML is invalid' do
      before do
        write_formula('invalid', "title: [unclosed bracket")
      end

      it 'raises ParseError' do
        expect { parser.parse('invalid') }
          .to raise_error(Eluent::Formulas::ParseError, /Invalid YAML/)
      end
    end

    context 'when formula has no title' do
      before do
        write_formula('no-title', <<~YAML)
          id: no-title
          steps:
            - id: step1
              title: Step
        YAML
      end

      it 'raises ParseError' do
        expect { parser.parse('no-title') }
          .to raise_error(Eluent::Formulas::ParseError, /must have a title/)
      end
    end

    context 'when formula has no steps' do
      before do
        write_formula('no-steps', <<~YAML)
          id: no-steps
          title: No Steps
          steps: []
        YAML
      end

      it 'raises ParseError' do
        expect { parser.parse('no-steps') }
          .to raise_error(Eluent::Formulas::ParseError, /must have at least one step/)
      end
    end

    context 'when formula has duplicate step IDs' do
      before do
        write_formula('dup-steps', <<~YAML)
          id: dup-steps
          title: Duplicate Steps
          steps:
            - id: step1
              title: First
            - id: step1
              title: Duplicate
        YAML
      end

      it 'raises ParseError' do
        expect { parser.parse('dup-steps') }
          .to raise_error(Eluent::Formulas::ParseError, /Duplicate step IDs/)
      end
    end

    context 'when step depends on unknown step' do
      before do
        write_formula('bad-dep', <<~YAML)
          id: bad-dep
          title: Bad Dependency
          steps:
            - id: step1
              title: Step
              depends_on:
                - nonexistent
        YAML
      end

      it 'raises ParseError' do
        expect { parser.parse('bad-dep') }
          .to raise_error(Eluent::Formulas::ParseError, /depends on unknown step/)
      end
    end
  end

  describe '#list' do
    before do
      write_formula('workflow-a', <<~YAML)
        id: workflow-a
        title: Workflow A
        version: 2
        steps:
          - id: step1
            title: Step 1
          - id: step2
            title: Step 2
        variables:
          name:
            required: true
      YAML

      write_formula('workflow-b', <<~YAML)
        id: workflow-b
        title: Workflow B
        phase: ephemeral
        steps:
          - id: step1
            title: Step
      YAML
    end

    it 'returns list of formula summaries' do
      list = parser.list
      expect(list.size).to eq(2)
    end

    it 'includes formula metadata' do
      list = parser.list
      workflow_a = list.find { |f| f[:id] == 'workflow-a' }

      expect(workflow_a[:title]).to eq('Workflow A')
      expect(workflow_a[:version]).to eq(2)
      expect(workflow_a[:steps_count]).to eq(2)
      expect(workflow_a[:variables_count]).to eq(1)
    end

    it 'returns formulas sorted by id' do
      list = parser.list
      expect(list.map { |f| f[:id] }).to eq(%w[workflow-a workflow-b])
    end

    it 'returns empty array when no formulas exist' do
      FileUtils.rm_rf(paths.formulas_dir)
      expect(parser.list).to eq([])
    end
  end

  describe '#exists?' do
    before do
      write_formula('existing', <<~YAML)
        id: existing
        title: Existing
        steps:
          - id: step1
            title: Step
      YAML
    end

    it 'returns true when formula exists' do
      expect(parser.exists?('existing')).to be true
    end

    it 'returns false when formula does not exist' do
      expect(parser.exists?('nonexistent')).to be false
    end
  end

  describe '#save' do
    let(:formula) do
      Eluent::Models::Formula.new(
        id: 'new-formula',
        title: 'New Formula',
        variables: { name: { required: true } },
        steps: [
          { id: 'step1', title: 'Step 1' },
          { id: 'step2', title: 'Step 2', depends_on: ['step1'] }
        ]
      )
    end

    it 'saves formula to YAML file' do
      parser.save(formula)
      expect(File.exist?(File.join(paths.formulas_dir, 'new-formula.yaml'))).to be true
    end

    it 'can be parsed back' do
      parser.save(formula)
      loaded = parser.parse('new-formula')

      expect(loaded.id).to eq('new-formula')
      expect(loaded.steps.size).to eq(2)
    end
  end

  private

  def write_formula(id, content)
    File.write(File.join(paths.formulas_dir, "#{id}.yaml"), content)
  end
end
