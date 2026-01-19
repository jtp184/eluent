# frozen_string_literal: true

RSpec.describe Eluent::Models::Formula do
  let(:minimal_formula) do
    described_class.new(
      id: 'test-formula',
      title: 'Test Formula',
      steps: [{ id: 'step-1', title: 'Step 1' }]
    )
  end

  let(:full_formula) do
    described_class.new(
      id: 'full-formula',
      title: 'Full Test: {{name}}',
      description: 'A complete formula with {{name}}',
      version: 2,
      phase: :ephemeral,
      variables: {
        name: { description: 'The name', required: true },
        component: { default: 'core', enum: %w[core api ui] }
      },
      steps: [
        { id: 'design', title: 'Design {{name}}', issue_type: :task },
        { id: 'implement', title: 'Implement {{name}}', depends_on: ['design'] }
      ],
      metadata: { author: 'test' }
    )
  end

  describe '#initialize' do
    it 'creates a formula with required attributes' do
      expect(minimal_formula.id).to eq('test-formula')
      expect(minimal_formula.title).to eq('Test Formula')
      expect(minimal_formula.steps.size).to eq(1)
    end

    it 'sets default values' do
      expect(minimal_formula.version).to eq(1)
      expect(minimal_formula.phase).to eq(:persistent)
      expect(minimal_formula.variables).to eq({})
      expect(minimal_formula.metadata).to eq({})
    end

    it 'validates formula id format' do
      expect { described_class.new(id: 'INVALID_ID', title: 'Test', steps: [{ title: 'Step' }]) }
        .to raise_error(Eluent::Models::ValidationError, /must match/)
    end

    it 'validates formula id is not blank' do
      expect { described_class.new(id: '', title: 'Test', steps: [{ title: 'Step' }]) }
        .to raise_error(Eluent::Models::ValidationError, /cannot be blank/)
    end

    it 'validates version is positive' do
      expect { described_class.new(id: 'test', title: 'Test', version: 0, steps: [{ title: 'Step' }]) }
        .to raise_error(Eluent::Models::ValidationError, /must be positive/)
    end

    it 'validates phase' do
      expect { described_class.new(id: 'test', title: 'Test', phase: :invalid, steps: [{ title: 'Step' }]) }
        .to raise_error(Eluent::Models::ValidationError, /invalid phase/)
    end

    it 'builds Variable objects from hash' do
      expect(full_formula.variables['name']).to be_a(Eluent::Models::Variable)
      expect(full_formula.variables['name'].required?).to be true
    end

    it 'builds Step objects from hash' do
      expect(full_formula.steps.first).to be_a(Eluent::Models::Step)
      expect(full_formula.steps.first.title).to eq('Design {{name}}')
    end
  end

  describe '#persistent?' do
    it 'returns true when phase is persistent' do
      expect(minimal_formula.persistent?).to be true
    end

    it 'returns false when phase is ephemeral' do
      expect(full_formula.persistent?).to be false
    end
  end

  describe '#ephemeral?' do
    it 'returns false when phase is persistent' do
      expect(minimal_formula.ephemeral?).to be false
    end

    it 'returns true when phase is ephemeral' do
      expect(full_formula.ephemeral?).to be true
    end
  end

  describe '#variable_names' do
    it 'returns array of variable names' do
      expect(full_formula.variable_names).to contain_exactly('name', 'component')
    end

    it 'returns empty array when no variables' do
      expect(minimal_formula.variable_names).to be_empty
    end
  end

  describe '#required_variables' do
    it 'returns only required variables' do
      required = full_formula.required_variables
      expect(required.keys).to contain_exactly('name')
    end
  end

  describe '#optional_variables' do
    it 'returns only optional variables' do
      optional = full_formula.optional_variables
      expect(optional.keys).to contain_exactly('component')
    end
  end

  describe '#step_by_id' do
    it 'finds step by id' do
      step = full_formula.step_by_id('design')
      expect(step.title).to eq('Design {{name}}')
    end

    it 'returns nil for unknown step' do
      expect(full_formula.step_by_id('unknown')).to be_nil
    end
  end

  describe '#to_h' do
    subject(:hash) { full_formula.to_h }

    it 'includes _type marker' do
      expect(hash[:_type]).to eq('formula')
    end

    it 'includes all attributes' do
      expect(hash[:id]).to eq('full-formula')
      expect(hash[:title]).to eq('Full Test: {{name}}')
      expect(hash[:version]).to eq(2)
      expect(hash[:phase]).to eq('ephemeral')
    end

    it 'serializes variables' do
      expect(hash[:variables]).to be_a(Hash)
      expect(hash[:variables]['name']).to include(:required)
    end

    it 'serializes steps' do
      expect(hash[:steps]).to be_an(Array)
      expect(hash[:steps].first[:id]).to eq('design')
    end
  end

  describe '#==' do
    it 'is equal to formula with same id' do
      other = described_class.new(id: 'test-formula', title: 'Different', steps: [{ title: 'Other' }])
      expect(minimal_formula).to eq(other)
    end

    it 'is not equal to formula with different id' do
      other = described_class.new(id: 'other-formula', title: 'Test', steps: [{ title: 'Step' }])
      expect(minimal_formula).not_to eq(other)
    end
  end
end

RSpec.describe Eluent::Models::Variable do
  let(:required_var) { described_class.new(name: 'name', required: true, description: 'The name') }
  let(:optional_var) { described_class.new(name: 'component', default: 'core', enum: %w[core api]) }
  let(:pattern_var) { described_class.new(name: 'version', pattern: '\d+\.\d+') }

  describe '#initialize' do
    it 'creates a variable with attributes' do
      expect(required_var.name).to eq('name')
      expect(required_var.description).to eq('The name')
    end

    it 'compiles pattern as Regexp' do
      expect(pattern_var.pattern).to be_a(Regexp)
    end

    it 'raises ValidationError for invalid regex pattern' do
      expect { described_class.new(name: 'bad', pattern: '[invalid') }
        .to raise_error(Eluent::Models::ValidationError, /invalid pattern for variable 'bad'/)
    end
  end

  describe '#required?' do
    it 'returns true when required and no default' do
      expect(required_var.required?).to be true
    end

    it 'returns false when has default' do
      var = described_class.new(name: 'test', required: true, default: 'val')
      expect(var.required?).to be false
    end

    it 'returns false when not required' do
      expect(optional_var.required?).to be false
    end
  end

  describe '#default?' do
    it 'returns true when default is set' do
      expect(optional_var.default?).to be true
    end

    it 'returns false when no default' do
      expect(required_var.default?).to be false
    end
  end

  describe '#enum?' do
    it 'returns true when enum is set' do
      expect(optional_var.enum?).to be true
    end

    it 'returns falsey when no enum' do
      expect(required_var.enum?).to be_falsey
    end
  end

  describe '#pattern?' do
    it 'returns true when pattern is set' do
      expect(pattern_var.pattern?).to be true
    end

    it 'returns false when no pattern' do
      expect(required_var.pattern?).to be false
    end
  end

  describe '#validate_value' do
    it 'returns error when required value is nil' do
      errors = required_var.validate_value(nil)
      expect(errors).to include('name is required')
    end

    it 'returns empty when required value is provided' do
      errors = required_var.validate_value('MyFeature')
      expect(errors).to be_empty
    end

    it 'returns error when value not in enum' do
      errors = optional_var.validate_value('invalid')
      expect(errors).to include('component must be one of: core, api')
    end

    it 'returns empty when value in enum' do
      errors = optional_var.validate_value('core')
      expect(errors).to be_empty
    end

    it 'returns error when value does not match pattern' do
      errors = pattern_var.validate_value('invalid')
      expect(errors.first).to match(/must match pattern/)
    end

    it 'returns empty when value matches pattern' do
      errors = pattern_var.validate_value('1.0')
      expect(errors).to be_empty
    end
  end

  describe '#to_h' do
    it 'includes only non-empty attributes' do
      hash = required_var.to_h
      expect(hash).to include(:required, :description)
      expect(hash).not_to include(:default, :enum, :pattern)
    end

    it 'includes pattern source as string' do
      hash = pattern_var.to_h
      expect(hash[:pattern]).to eq('\d+\.\d+')
    end
  end
end

RSpec.describe Eluent::Models::Step do
  let(:minimal_step) { described_class.new(id: 'step-1', title: 'Test Step') }
  let(:full_step) do
    described_class.new(
      id: 'implement',
      title: 'Implement Feature',
      issue_type: :feature,
      description: 'Full implementation',
      depends_on: %w[design review],
      assignee: 'dev',
      priority: 1,
      labels: %w[urgent backend]
    )
  end

  describe '#initialize' do
    it 'creates a step with required attributes' do
      expect(minimal_step.id).to eq('step-1')
      expect(minimal_step.title).to eq('Test Step')
    end

    it 'sets default issue_type to task' do
      expect(minimal_step.issue_type).to eq(Eluent::Models::IssueType[:task])
    end

    it 'converts depends_on to array of strings' do
      expect(full_step.depends_on).to eq(%w[design review])
    end
  end

  describe '#dependencies?' do
    it 'returns false when no dependencies' do
      expect(minimal_step.dependencies?).to be false
    end

    it 'returns true when dependencies exist' do
      expect(full_step.dependencies?).to be true
    end
  end

  describe '#to_h' do
    it 'includes only non-empty attributes' do
      hash = minimal_step.to_h
      expect(hash.keys).to contain_exactly(:id, :title)
    end

    it 'excludes task issue_type (default)' do
      hash = minimal_step.to_h
      expect(hash).not_to include(:issue_type)
    end

    it 'includes non-default issue_type' do
      hash = full_step.to_h
      expect(hash[:issue_type]).to eq('feature')
    end

    it 'includes depends_on when present' do
      hash = full_step.to_h
      expect(hash[:depends_on]).to eq(%w[design review])
    end
  end
end
