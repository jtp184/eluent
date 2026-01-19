# frozen_string_literal: true

RSpec.describe Eluent::Formulas::Instantiator do
  let(:root_path) { Dir.mktmpdir }
  let(:repository) do
    repo = Eluent::Storage::JsonlRepository.new(root_path)
    repo.init(repo_name: 'testrepo')
    repo
  end

  after { FileUtils.rm_rf(root_path) }

  let(:instantiator) { described_class.new(repository: repository) }

  let(:formula) do
    Eluent::Models::Formula.new(
      id: 'test-workflow',
      title: 'Test: {{name}}',
      description: 'Workflow for {{name}}',
      variables: {
        name: { required: true }
      },
      steps: [
        { id: 'design', title: 'Design {{name}}', priority: 1 },
        { id: 'implement', title: 'Implement {{name}}', depends_on: ['design'] },
        { id: 'test', title: 'Test {{name}}', depends_on: ['implement'] }
      ]
    )
  end

  describe '#instantiate' do
    context 'without parent_id' do
      it 'creates a root epic atom' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        expect(result.root_atom).not_to be_nil
        expect(result.root_atom.issue_type).to eq(Eluent::Models::IssueType[:epic])
        expect(result.root_atom.title).to eq('Test: Auth')
      end

      it 'creates step atoms as children' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        expect(result.step_atoms.size).to eq(3)
        result.step_atoms.each_value do |atom|
          expect(atom.parent_id).to eq(result.root_atom.id)
        end
      end

      it 'substitutes variables in step titles' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        design_atom = result.atom_for_step('design')
        expect(design_atom.title).to eq('Design Auth')
      end

      it 'creates dependency bonds' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        expect(result.bonds.size).to eq(2)

        design = result.atom_for_step('design')
        implement = result.atom_for_step('implement')
        test_atom = result.atom_for_step('test')

        # design blocks implement
        expect(result.bonds).to include(satisfy { |b|
          b.source_id == design.id && b.target_id == implement.id
        })

        # implement blocks test
        expect(result.bonds).to include(satisfy { |b|
          b.source_id == implement.id && b.target_id == test_atom.id
        })
      end

      it 'stores formula_id in root atom metadata' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        expect(result.root_atom.metadata[:formula_id]).to eq('test-workflow')
        expect(result.root_atom.metadata[:formula_version]).to eq(1)
      end

      it 'stores formula_step_id in step atom metadata' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        design_atom = result.atom_for_step('design')
        expect(design_atom.metadata[:formula_step_id]).to eq('design')
      end

      it 'preserves step priority' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' })

        design_atom = result.atom_for_step('design')
        expect(design_atom.priority).to eq(1)
      end
    end

    context 'with parent_id' do
      let(:existing_atom) do
        repository.create_atom(title: 'Existing Epic', issue_type: :epic)
      end

      it 'attaches steps to existing atom instead of creating root' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' }, parent_id: existing_atom.id)

        expect(result.root_atom.id).to eq(existing_atom.id)
        expect(result.step_atoms.size).to eq(3)
      end

      it 'creates step atoms as children of existing atom' do
        result = instantiator.instantiate(formula, variables: { name: 'Auth' }, parent_id: existing_atom.id)

        result.step_atoms.each_value do |atom|
          expect(atom.parent_id).to eq(existing_atom.id)
        end
      end

      it 'raises error when parent_id not found' do
        expect { instantiator.instantiate(formula, variables: { name: 'Auth' }, parent_id: 'nonexistent') }
          .to raise_error(Eluent::Registry::IdNotFoundError)
      end
    end

    context 'with ephemeral formula' do
      let(:ephemeral_formula) do
        Eluent::Models::Formula.new(
          id: 'ephemeral-workflow',
          title: 'Ephemeral: {{name}}',
          retention: :ephemeral,
          variables: { name: { required: true } },
          steps: [{ id: 'step1', title: 'Step for {{name}}' }]
        )
      end

      it 'creates atoms as ephemeral' do
        result = instantiator.instantiate(ephemeral_formula, variables: { name: 'Test' })

        # Check that atoms were created (ephemeral would be in ephemeral file)
        expect(result.all_atoms.size).to eq(2)
      end
    end
  end

  describe Eluent::Formulas::InstantiationResult do
    # Override instantiator with explicit class to avoid described_class changing
    let(:instantiator) { Eluent::Formulas::Instantiator.new(repository: repository) }

    let(:test_formula) do
      Eluent::Models::Formula.new(
        id: 'result-test',
        title: 'Result Test',
        variables: { name: { required: true } },
        steps: [{ id: 'step1', title: 'Step 1' }, { id: 'step2', title: 'Step 2' }]
      )
    end

    let(:result) do
      instantiator.instantiate(test_formula, variables: { name: 'Test' })
    end

    describe '#all_atoms' do
      it 'returns root atom and all step atoms' do
        atoms = result.all_atoms
        expect(atoms.size).to eq(3) # 1 root + 2 steps
        expect(atoms).to include(result.root_atom)
      end
    end

    describe '#to_h' do
      it 'returns hash representation' do
        hash = result.to_h

        expect(hash[:formula_id]).to eq('result-test')
        expect(hash[:root_atom_id]).to eq(result.root_atom.id)
        expect(hash[:step_atoms]).to be_a(Hash)
        expect(hash[:bonds_count]).to eq(0)
      end
    end
  end
end
