# frozen_string_literal: true

RSpec.describe Eluent::Sync::MergeEngine do
  let(:engine) { described_class.new }

  describe '#merge' do
    context 'with atoms' do
      context 'when local has new atom' do
        let(:base) { { atoms: [], bonds: [], comments: [] } }
        let(:local_atom) { build(:atom) }
        let(:local) { { atoms: [local_atom], bonds: [], comments: [] } }
        let(:remote) { { atoms: [], bonds: [], comments: [] } }

        it 'includes the new local atom' do
          result = engine.merge(base: base, local: local, remote: remote)
          expect(result.atoms).to include(local_atom)
        end
      end

      context 'when remote has new atom' do
        let(:base) { { atoms: [], bonds: [], comments: [] } }
        let(:local) { { atoms: [], bonds: [], comments: [] } }
        let(:remote_atom) { build(:atom) }
        let(:remote) { { atoms: [remote_atom], bonds: [], comments: [] } }

        it 'includes the new remote atom' do
          result = engine.merge(base: base, local: local, remote: remote)
          expect(result.atoms).to include(remote_atom)
        end
      end

      context 'when merging scalar fields with LWW' do
        let(:atom_id) { generate(:atom_id) }
        let(:base_atom) { build(:atom, id: atom_id, title: 'Original', updated_at: Time.utc(2025, 1, 1)) }
        let(:local_atom) { build(:atom, id: atom_id, title: 'Local Change', updated_at: Time.utc(2025, 1, 2)) }
        let(:remote_atom) { build(:atom, id: atom_id, title: 'Remote Change', updated_at: Time.utc(2025, 1, 3)) }

        let(:base) { { atoms: [base_atom], bonds: [], comments: [] } }
        let(:local) { { atoms: [local_atom], bonds: [], comments: [] } }
        let(:remote) { { atoms: [remote_atom], bonds: [], comments: [] } }

        it 'uses remote value when remote is newer' do
          result = engine.merge(base: base, local: local, remote: remote)
          merged_atom = result.atoms.find { |a| a.id == atom_id }
          expect(merged_atom.title).to eq('Remote Change')
        end
      end

      context 'when merging set fields (labels)' do
        let(:atom_id) { generate(:atom_id) }
        let(:base_atom) { build(:atom, id: atom_id, labels: %w[bug]) }
        let(:local_atom) { build(:atom, id: atom_id, labels: %w[bug frontend]) }
        let(:remote_atom) { build(:atom, id: atom_id, labels: %w[bug backend]) }

        let(:base) { { atoms: [base_atom], bonds: [], comments: [] } }
        let(:local) { { atoms: [local_atom], bonds: [], comments: [] } }
        let(:remote) { { atoms: [remote_atom], bonds: [], comments: [] } }

        it 'unions labels from both sides' do
          result = engine.merge(base: base, local: local, remote: remote)
          merged_atom = result.atoms.find { |a| a.id == atom_id }
          expect(merged_atom.labels.to_a).to contain_exactly('bug', 'frontend', 'backend')
        end
      end

      context 'when local unchanged from base' do
        let(:atom_id) { generate(:atom_id) }
        let(:base_atom) { build(:atom, id: atom_id, title: 'Original') }
        let(:local_atom) { build(:atom, id: atom_id, title: 'Original') }
        let(:remote_atom) { build(:atom, id: atom_id, title: 'Remote Change') }

        let(:base) { { atoms: [base_atom], bonds: [], comments: [] } }
        let(:local) { { atoms: [local_atom], bonds: [], comments: [] } }
        let(:remote) { { atoms: [remote_atom], bonds: [], comments: [] } }

        it 'takes remote value' do
          result = engine.merge(base: base, local: local, remote: remote)
          merged_atom = result.atoms.find { |a| a.id == atom_id }
          expect(merged_atom.title).to eq('Remote Change')
        end
      end
    end

    context 'with bonds' do
      let(:base) { { atoms: [], bonds: [], comments: [] } }
      let(:local_bond) { build(:bond, source_id: 'a', target_id: 'b') }
      let(:remote_bond) { build(:bond, source_id: 'a', target_id: 'c') }
      let(:local) { { atoms: [], bonds: [local_bond], comments: [] } }
      let(:remote) { { atoms: [], bonds: [remote_bond], comments: [] } }

      it 'unions bonds from both sides' do
        result = engine.merge(base: base, local: local, remote: remote)
        expect(result.bonds.size).to eq(2)
      end

      context 'with duplicate bonds' do
        let(:dup_bond) { build(:bond, source_id: local_bond.source_id, target_id: local_bond.target_id) }
        let(:remote) { { atoms: [], bonds: [dup_bond], comments: [] } }

        it 'deduplicates by key' do
          result = engine.merge(base: base, local: local, remote: remote)
          expect(result.bonds.size).to eq(1)
        end
      end
    end

    context 'with comments' do
      let(:parent_id) { generate(:atom_id) }
      let(:base) { { atoms: [], bonds: [], comments: [] } }
      let(:local_comment) { build(:comment, parent_id: parent_id, content: 'Local') }
      let(:remote_comment) { build(:comment, parent_id: parent_id, content: 'Remote') }
      let(:local) { { atoms: [], bonds: [], comments: [local_comment] } }
      let(:remote) { { atoms: [], bonds: [], comments: [remote_comment] } }

      it 'unions comments from both sides' do
        result = engine.merge(base: base, local: local, remote: remote)
        expect(result.comments.size).to eq(2)
      end
    end

    context 'with first sync (no base)' do
      let(:base) { { atoms: [], bonds: [], comments: [] } }
      let(:local_atom) { build(:atom) }
      let(:remote_atom) { build(:atom) }
      let(:local) { { atoms: [local_atom], bonds: [], comments: [] } }
      let(:remote) { { atoms: [remote_atom], bonds: [], comments: [] } }

      it 'includes atoms from both sides' do
        result = engine.merge(base: base, local: local, remote: remote)
        expect(result.atoms.size).to eq(2)
      end
    end
  end
end
