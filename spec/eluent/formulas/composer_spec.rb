# frozen_string_literal: true

RSpec.describe Eluent::Formulas::Composer, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }
  let(:parser) { Eluent::Formulas::Parser.new(paths: paths) }
  let(:composer) { described_class.new(parser: parser) }

  before do
    setup_eluent_directory(root_path)
    FileUtils.mkdir_p(paths.formulas_dir)

    write_formula('design', <<~YAML)
      id: design
      title: Design Phase
      variables:
        name:
          required: true
      steps:
        - id: research
          title: Research {{name}}
        - id: spec
          title: Write spec for {{name}}
          depends_on:
            - research
    YAML

    write_formula('implement', <<~YAML)
      id: implement
      title: Implementation Phase
      variables:
        name:
          required: true
        language:
          default: ruby
      steps:
        - id: code
          title: Code {{name}} in {{language}}
        - id: test
          title: Test {{name}}
          depends_on:
            - code
    YAML
  end

  describe '#compose' do
    context 'with sequential type' do
      it 'creates a composite formula' do
        result = composer.compose(%w[design implement], new_id: 'full-workflow', type: :sequential)

        expect(result).to be_a(Eluent::Models::Formula)
        expect(result.id).to eq('full-workflow')
      end

      it 'includes all steps from both formulas' do
        result = composer.compose(%w[design implement], new_id: 'combined', type: :sequential)

        expect(result.steps.size).to eq(4)
      end

      it 'prefixes step IDs with formula ID' do
        result = composer.compose(%w[design implement], new_id: 'combined', type: :sequential)

        step_ids = result.steps.map(&:id)
        expect(step_ids).to include('design-research', 'design-spec', 'implement-code', 'implement-test')
      end

      it 'creates sequential dependency between formulas' do
        result = composer.compose(%w[design implement], new_id: 'combined', type: :sequential)

        # First step of implement should depend on last step of design
        code_step = result.steps.find { |s| s.id == 'implement-code' }
        expect(code_step.depends_on).to include('design-spec')
      end

      it 'merges variables with prefixes' do
        result = composer.compose(%w[design implement], new_id: 'combined', type: :sequential)

        expect(result.variables).to have_key('design-name')
        expect(result.variables).to have_key('implement-name')
        expect(result.variables).to have_key('implement-language')
      end

      it 'stores composition metadata' do
        result = composer.compose(%w[design implement], new_id: 'combined', type: :sequential)

        expect(result.metadata[:composition_type]).to eq('sequential')
        expect(result.metadata[:source_formulas]).to eq(%w[design implement])
      end
    end

    context 'with parallel type' do
      it 'creates formula without inter-formula dependencies' do
        result = composer.compose(%w[design implement], new_id: 'parallel', type: :parallel)

        # First step of implement should NOT depend on design steps
        code_step = result.steps.find { |s| s.id == 'implement-code' }
        expect(code_step.depends_on).not_to include('design-spec')
        expect(code_step.depends_on).to be_empty
      end

      it 'stores parallel composition type in metadata' do
        result = composer.compose(%w[design implement], new_id: 'parallel', type: :parallel)

        expect(result.metadata[:composition_type]).to eq('parallel')
      end
    end

    context 'with conditional type' do
      it 'adds branch variable' do
        result = composer.compose(%w[design implement], new_id: 'conditional', type: :conditional)

        expect(result.variables).to have_key('branch')
        branch_var = result.variables['branch']
        expect(branch_var).to be_a(Eluent::Models::Variable)
        expect(branch_var.enum).to contain_exactly('design', 'implement')
      end

      it 'adds condition labels to steps' do
        result = composer.compose(%w[design implement], new_id: 'conditional', type: :conditional)

        design_step = result.steps.find { |s| s.id == 'design-research' }
        expect(design_step.labels).to include('condition:branch=design')

        implement_step = result.steps.find { |s| s.id == 'implement-code' }
        expect(implement_step.labels).to include('condition:branch=implement')
      end
    end

    context 'with custom title' do
      it 'uses provided title' do
        result = composer.compose(%w[design implement], new_id: 'combined', type: :sequential, title: 'My Workflow')

        expect(result.title).to eq('My Workflow')
      end
    end

    context 'with errors' do
      it 'raises error when fewer than 2 formulas' do
        expect { composer.compose(['design'], new_id: 'single', type: :sequential) }
          .to raise_error(Eluent::Formulas::ParseError, /At least two formulas/)
      end

      it 'raises error for invalid composition type' do
        expect { composer.compose(%w[design implement], new_id: 'invalid', type: :unknown) }
          .to raise_error(Eluent::Formulas::ParseError, /Invalid composition type/)
      end
    end
  end

  private

  def write_formula(id, content)
    File.write(File.join(paths.formulas_dir, "#{id}.yaml"), content)
  end
end
