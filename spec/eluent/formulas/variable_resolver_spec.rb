# frozen_string_literal: true

RSpec.describe Eluent::Formulas::VariableResolver do
  let(:formula) do
    Eluent::Models::Formula.new(
      id: 'test-formula',
      title: 'Test: {{name}}',
      description: 'Feature for {{component}}',
      variables: {
        name: { required: true, description: 'Feature name' },
        component: { default: 'core', enum: %w[core api ui] },
        version: { pattern: '\d+\.\d+' },
        owner: { default: 'unassigned' }
      },
      steps: [
        { id: 'step1', title: 'Design {{name}} for {{component}}' },
        { id: 'step2', title: 'Implement {{name}}', assignee: '{{owner}}', depends_on: ['step1'] }
      ]
    )
  end

  let(:resolver) { described_class.new(formula) }

  describe '#resolve' do
    it 'returns resolved values with defaults applied' do
      resolved = resolver.resolve(name: 'MyFeature')
      expect(resolved['name']).to eq('MyFeature')
      expect(resolved['component']).to eq('core')
    end

    it 'allows overriding defaults' do
      resolved = resolver.resolve(name: 'MyFeature', component: 'api')
      expect(resolved['component']).to eq('api')
    end

    it 'normalizes keys to strings' do
      resolved = resolver.resolve(name: 'MyFeature')
      expect(resolved.keys).to all(be_a(String))
    end
  end

  describe '#validate!' do
    it 'raises VariableError when required variable is missing' do
      expect { resolver.validate!({}) }
        .to raise_error(Eluent::Formulas::VariableError, /name is required/)
    end

    it 'raises VariableError when enum constraint is violated' do
      expect { resolver.validate!('name' => 'Test', 'component' => 'invalid') }
        .to raise_error(Eluent::Formulas::VariableError, /must be one of/)
    end

    it 'raises VariableError when pattern constraint is violated' do
      expect { resolver.validate!('name' => 'Test', 'version' => 'invalid') }
        .to raise_error(Eluent::Formulas::VariableError, /must match pattern/)
    end

    it 'warns about unknown variables' do
      expect { resolver.validate!('name' => 'Test', 'unknown' => 'value') }
        .to raise_error(Eluent::Formulas::VariableError, /Unknown variable: unknown/)
    end

    it 'warns about undefined referenced variables' do
      # Create a formula with a reference to an undefined variable
      bad_formula = Eluent::Models::Formula.new(
        id: 'bad-formula',
        title: 'Bad: {{undefined_var}}',
        variables: { name: { required: true } },
        steps: [{ id: 'step1', title: 'Do {{name}}' }]
      )
      bad_resolver = described_class.new(bad_formula)

      expect { bad_resolver.validate!('name' => 'Test') }
        .to raise_error(Eluent::Formulas::VariableError, /undefined_var.*not defined/)
    end

    it 'returns true when all constraints pass' do
      # Note: 'owner' is referenced but not defined in variables, so this will fail
      # For a passing case, we need to either add owner to variables or use a formula without it
      formula_without_owner = Eluent::Models::Formula.new(
        id: 'simple',
        title: 'Test: {{name}}',
        variables: { name: { required: true } },
        steps: [{ id: 'step1', title: 'Do {{name}}' }]
      )
      simple_resolver = described_class.new(formula_without_owner)

      expect(simple_resolver.validate!('name' => 'Test')).to be true
    end
  end

  describe '#substitute' do
    it 'replaces {{var}} with resolved values' do
      result = resolver.substitute('Hello {{name}} in {{component}}', { 'name' => 'World', 'component' => 'core' })
      expect(result).to eq('Hello World in core')
    end

    it 'leaves unknown variables unchanged' do
      result = resolver.substitute('Hello {{unknown}}', { 'name' => 'World' })
      expect(result).to eq('Hello {{unknown}}')
    end

    it 'returns nil for nil input' do
      expect(resolver.substitute(nil, { 'name' => 'World' })).to be_nil
    end

    it 'returns non-strings unchanged' do
      expect(resolver.substitute(123, { 'name' => 'World' })).to eq(123)
    end
  end

  describe '#substitute_step' do
    it 'substitutes variables in step title' do
      resolved = { 'name' => 'Auth', 'component' => 'api', 'owner' => 'dev' }
      step = formula.steps.first
      result = resolver.substitute_step(step, resolved)

      expect(result.title).to eq('Design Auth for api')
    end

    it 'substitutes variables in assignee' do
      resolved = { 'name' => 'Auth', 'owner' => 'alice' }
      step = formula.steps.last
      result = resolver.substitute_step(step, resolved)

      expect(result.assignee).to eq('alice')
    end

    it 'preserves step id and other attributes' do
      resolved = { 'name' => 'Auth', 'component' => 'api' }
      step = formula.steps.first
      result = resolver.substitute_step(step, resolved)

      expect(result.id).to eq('step1')
      expect(result.issue_type).to eq(step.issue_type)
    end
  end

  describe '#substitute_formula' do
    it 'substitutes variables in formula title' do
      resolved = { 'name' => 'Auth', 'component' => 'api', 'owner' => 'dev' }
      result = resolver.substitute_formula(resolved)

      expect(result.title).to eq('Test: Auth')
    end

    it 'substitutes variables in all steps' do
      resolved = { 'name' => 'Auth', 'component' => 'api', 'owner' => 'dev' }
      result = resolver.substitute_formula(resolved)

      expect(result.steps.first.title).to eq('Design Auth for api')
      expect(result.steps.last.title).to eq('Implement Auth')
    end
  end

  describe '#extract_variables' do
    it 'extracts variable names from text' do
      vars = resolver.extract_variables('Hello {{name}} in {{component}}')
      expect(vars).to contain_exactly('name', 'component')
    end

    it 'returns unique variable names' do
      vars = resolver.extract_variables('{{name}} and {{name}} again')
      expect(vars).to eq(['name'])
    end

    it 'returns empty array for nil' do
      expect(resolver.extract_variables(nil)).to eq([])
    end
  end

  describe '#all_referenced_variables' do
    it 'returns all variables referenced in formula text fields' do
      referenced = resolver.all_referenced_variables
      expect(referenced).to include('name', 'component', 'owner')
    end
  end
end
