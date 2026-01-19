# frozen_string_literal: true

RSpec.describe Eluent::Formulas::Distiller do
  let(:root_path) { Dir.mktmpdir }
  let(:repository) do
    repo = Eluent::Storage::JsonlRepository.new(root_path)
    repo.init(repo_name: 'testrepo')
    repo
  end

  after { FileUtils.rm_rf(root_path) }

  let(:distiller) { described_class.new(repository: repository) }

  describe '#distill' do
    let!(:root_atom) do
      repository.create_atom(
        title: 'Auth Feature',
        description: 'Authentication feature',
        issue_type: :epic
      )
    end

    let!(:design_atom) do
      repository.create_atom(
        title: 'Design Auth',
        issue_type: :task,
        parent_id: root_atom.id,
        priority: 1
      )
    end

    let!(:implement_atom) do
      repository.create_atom(
        title: 'Implement Auth',
        issue_type: :task,
        parent_id: root_atom.id
      )
    end

    let!(:blocking_bond) do
      repository.create_bond(
        source_id: design_atom.id,
        target_id: implement_atom.id,
        dependency_type: :blocks
      )
    end

    it 'extracts formula from existing work hierarchy' do
      formula = distiller.distill(root_atom.id, formula_id: 'auth-workflow')

      expect(formula).to be_a(Eluent::Models::Formula)
      expect(formula.id).to eq('auth-workflow')
    end

    it 'uses root atom title as formula title' do
      formula = distiller.distill(root_atom.id, formula_id: 'auth-workflow')

      expect(formula.title).to eq('Auth Feature')
    end

    it 'creates steps from child atoms' do
      formula = distiller.distill(root_atom.id, formula_id: 'auth-workflow')

      expect(formula.steps.size).to eq(2)
      titles = formula.steps.map(&:title)
      expect(titles).to include('Design Auth', 'Implement Auth')
    end

    it 'preserves step dependencies from bonds' do
      formula = distiller.distill(root_atom.id, formula_id: 'auth-workflow')

      implement_step = formula.steps.find { |s| s.title == 'Implement Auth' }
      expect(implement_step.dependencies?).to be true
    end

    it 'preserves step priority' do
      formula = distiller.distill(root_atom.id, formula_id: 'auth-workflow')

      design_step = formula.steps.find { |s| s.title == 'Design Auth' }
      expect(design_step.priority).to eq(1)
    end

    it 'stores distilled_from metadata' do
      formula = distiller.distill(root_atom.id, formula_id: 'auth-workflow')

      expect(formula.metadata[:distilled_from]).to eq(root_atom.id)
      expect(formula.metadata[:distilled_at]).not_to be_nil
    end

    context 'with variable mappings' do
      it 'replaces literal values with variable references' do
        formula = distiller.distill(
          root_atom.id,
          formula_id: 'auth-workflow',
          literal_to_var_map: { 'Auth' => 'feature_name' }
        )

        expect(formula.title).to eq('{{feature_name}} Feature')

        design_step = formula.steps.find { |s| s.title.include?('Design') }
        expect(design_step.title).to eq('Design {{feature_name}}')
      end

      it 'creates variable definitions from mappings' do
        formula = distiller.distill(
          root_atom.id,
          formula_id: 'auth-workflow',
          literal_to_var_map: { 'Auth' => 'feature_name' }
        )

        expect(formula.variables).to have_key('feature_name')
        expect(formula.variables['feature_name'].required?).to be true
      end

      it 'handles overlapping mappings by replacing longest first' do
        # Create atom with title containing both "Auth" and "Authentication"
        auth_atom = repository.create_atom(
          title: 'Authentication Module',
          description: 'Auth system for the app',
          issue_type: :epic
        )
        repository.create_atom(title: 'Setup', parent_id: auth_atom.id)

        formula = distiller.distill(
          auth_atom.id,
          formula_id: 'overlapping-test',
          literal_to_var_map: {
            'Auth' => 'short',
            'Authentication' => 'full'
          }
        )

        # "Authentication" should be replaced with {{full}}, not "{{short}}entication"
        expect(formula.title).to eq('{{full}} Module')
        # "Auth" in description should be replaced with {{short}}
        expect(formula.description).to eq('{{short}} system for the app')
      end
    end

    it 'raises error when root atom not found' do
      expect { distiller.distill('nonexistent', formula_id: 'test') }
        .to raise_error(Eluent::Registry::IdNotFoundError)
    end
  end
end
