# frozen_string_literal: true

RSpec.describe Eluent::Storage::Indexer do
  subject(:indexer) { described_class.new }

  let(:atom1) { build(:atom, id: test_atom_id_for_repo('testrepo', 'ABCDEFGHKMNPQRST')) }
  let(:atom2) { build(:atom, id: test_atom_id_for_repo('testrepo', 'ZYXWVTSRQPNMKJHG')) }
  let(:atom3) { build(:atom, id: test_atom_id_for_repo('otherrepo', 'ABCDEFGHKMNPQRST')) }

  describe '#index_atom' do
    it 'adds atom to exact index' do
      indexer.index_atom(atom1)
      expect(indexer.find_by_id(atom1.id)).to eq(atom1)
    end

    it 'adds atom to randomness trie' do
      indexer.index_atom(atom1)
      expect(indexer.find_by_randomness_prefix('ABCD', repo: 'testrepo')).to include(atom1)
    end

    it 'ignores nil atoms' do
      expect { indexer.index_atom(nil) }.not_to raise_error
    end

    it 'ignores atoms without ids' do
      atom = build(:atom, id: nil)
      atom.id = nil
      expect { indexer.index_atom(atom) }.not_to raise_error
    end
  end

  describe '#remove_atom' do
    before { indexer.index_atom(atom1) }

    it 'removes atom from exact index' do
      indexer.remove_atom(atom1)
      expect(indexer.find_by_id(atom1.id)).to be_nil
    end

    it 'removes atom from randomness trie' do
      indexer.remove_atom(atom1)
      expect(indexer.find_by_randomness_prefix('ABCD', repo: 'testrepo')).not_to include(atom1)
    end
  end

  describe '#find_by_id' do
    it 'returns the atom for an exact ID match' do
      indexer.index_atom(atom1)
      expect(indexer.find_by_id(atom1.id)).to eq(atom1)
    end

    it 'returns nil for non-existent IDs' do
      expect(indexer.find_by_id('nonexistent')).to be_nil
    end
  end

  describe '#find_by_randomness_prefix' do
    before do
      indexer.index_atom(atom1)
      indexer.index_atom(atom2)
      indexer.index_atom(atom3)
    end

    it 'finds atoms by prefix within a repo' do
      results = indexer.find_by_randomness_prefix('ABCD', repo: 'testrepo')
      expect(results).to contain_exactly(atom1)
    end

    it 'searches all repos when repo is nil' do
      results = indexer.find_by_randomness_prefix('ABCD')
      expect(results).to contain_exactly(atom1, atom3)
    end

    it 'returns empty array for no matches' do
      results = indexer.find_by_randomness_prefix('ZZZZ', repo: 'testrepo')
      expect(results).to be_empty
    end
  end

  describe '#minimum_unique_prefix' do
    before do
      indexer.index_atom(atom1)
      indexer.index_atom(atom2)
    end

    it 'returns the minimum unique prefix' do
      prefix = indexer.minimum_unique_prefix('ABCDEFGHKMNPQRST')
      expect(prefix).not_to be_nil
      expect(prefix.length).to be >= 4
    end
  end

  describe '#all_atoms' do
    before do
      indexer.index_atom(atom1)
      indexer.index_atom(atom2)
    end

    it 'returns all indexed atoms' do
      expect(indexer.all_atoms).to contain_exactly(atom1, atom2)
    end
  end

  describe '#atoms_by_status' do
    let(:open_atom) { build(:atom, :open) }
    let(:closed_atom) { build(:atom, :closed) }

    before do
      indexer.index_atom(open_atom)
      indexer.index_atom(closed_atom)
    end

    it 'returns atoms with the specified status' do
      open_status = Eluent::Models::Status[:open]
      results = indexer.atoms_by_status(open_status)
      expect(results).to contain_exactly(open_atom)
    end
  end

  describe '#atoms_by_type' do
    let(:feature_atom) { build(:atom, :feature) }
    let(:bug_atom) { build(:atom, :bug) }

    before do
      indexer.index_atom(feature_atom)
      indexer.index_atom(bug_atom)
    end

    it 'returns atoms with the specified issue type' do
      feature_type = Eluent::Models::IssueType[:feature]
      results = indexer.atoms_by_type(feature_type)
      expect(results).to contain_exactly(feature_atom)
    end
  end

  describe '#children_of' do
    let(:parent) { build(:atom) }
    let(:child1) { build(:atom, parent_id: parent.id) }
    let(:child2) { build(:atom, parent_id: parent.id) }
    let(:other) { build(:atom) }

    before do
      [parent, child1, child2, other].each { |a| indexer.index_atom(a) }
    end

    it 'returns children of the specified parent' do
      results = indexer.children_of(parent.id)
      expect(results).to contain_exactly(child1, child2)
    end
  end

  describe 'bond indexing' do
    let(:bond) { build(:bond, source_id: atom1.id, target_id: atom2.id) }

    describe '#index_bond' do
      it 'indexes bond by source' do
        indexer.index_bond(bond)
        expect(indexer.bonds_from(atom1.id)).to include(bond)
      end

      it 'indexes bond by target' do
        indexer.index_bond(bond)
        expect(indexer.bonds_to(atom2.id)).to include(bond)
      end

      it 'does not duplicate bonds' do
        indexer.index_bond(bond)
        indexer.index_bond(bond)
        expect(indexer.bonds_from(atom1.id).length).to eq(1)
      end
    end

    describe '#remove_bond' do
      before { indexer.index_bond(bond) }

      it 'removes bond from source index' do
        indexer.remove_bond(bond)
        expect(indexer.bonds_from(atom1.id)).not_to include(bond)
      end

      it 'removes bond from target index' do
        indexer.remove_bond(bond)
        expect(indexer.bonds_to(atom2.id)).not_to include(bond)
      end
    end

    describe '#all_bonds' do
      let(:bond2) { build(:bond, source_id: atom2.id, target_id: atom1.id) }

      before do
        indexer.index_bond(bond)
        indexer.index_bond(bond2)
      end

      it 'returns all unique bonds' do
        expect(indexer.all_bonds).to contain_exactly(bond, bond2)
      end
    end
  end

  describe 'comment indexing' do
    let(:comment1) { build(:comment, parent_id: atom1.id) }
    let(:comment2) { build(:comment, parent_id: atom1.id) }
    let(:comment3) { build(:comment, parent_id: atom2.id) }

    describe '#index_comment' do
      it 'indexes comment by parent_id' do
        indexer.index_comment(comment1)
        expect(indexer.comments_for(atom1.id)).to include(comment1)
      end

      it 'does not duplicate comments' do
        indexer.index_comment(comment1)
        indexer.index_comment(comment1)
        expect(indexer.comments_for(atom1.id).length).to eq(1)
      end
    end

    describe '#remove_comment' do
      before { indexer.index_comment(comment1) }

      it 'removes comment from parent index' do
        indexer.remove_comment(comment1)
        expect(indexer.comments_for(atom1.id)).not_to include(comment1)
      end
    end

    describe '#comments_for' do
      before do
        indexer.index_comment(comment1)
        indexer.index_comment(comment2)
        indexer.index_comment(comment3)
      end

      it 'returns comments for the specified atom' do
        results = indexer.comments_for(atom1.id)
        expect(results).to contain_exactly(comment1, comment2)
      end

      it 'sorts comments by created_at' do
        older = build(:comment, :old, parent_id: atom1.id)
        recent = build(:comment, :recent, parent_id: atom1.id)
        indexer.index_comment(older)
        indexer.index_comment(recent)

        results = indexer.comments_for(atom1.id)
        expect(results.first.created_at).to be <= results.last.created_at
      end
    end

    describe '#all_comments' do
      before do
        indexer.index_comment(comment1)
        indexer.index_comment(comment2)
        indexer.index_comment(comment3)
      end

      it 'returns all indexed comments' do
        expect(indexer.all_comments).to contain_exactly(comment1, comment2, comment3)
      end
    end
  end

  describe '#atom_exists?' do
    it 'returns true for indexed atoms' do
      indexer.index_atom(atom1)
      expect(indexer.atom_exists?(atom1.id)).to be true
    end

    it 'returns false for non-indexed atoms' do
      expect(indexer.atom_exists?('nonexistent')).to be false
    end
  end

  describe '#atom_count' do
    it 'returns the number of indexed atoms' do
      expect(indexer.atom_count).to eq(0)
      indexer.index_atom(atom1)
      expect(indexer.atom_count).to eq(1)
      indexer.index_atom(atom2)
      expect(indexer.atom_count).to eq(2)
    end
  end

  describe '#bond_count' do
    let(:bond1) { build(:bond, source_id: atom1.id, target_id: atom2.id) }
    let(:bond2) { build(:bond, source_id: atom2.id, target_id: atom1.id) }

    it 'returns the number of indexed bonds' do
      expect(indexer.bond_count).to eq(0)
      indexer.index_bond(bond1)
      expect(indexer.bond_count).to eq(1)
      indexer.index_bond(bond2)
      expect(indexer.bond_count).to eq(2)
    end
  end

  describe '#clear' do
    before do
      indexer.index_atom(atom1)
      indexer.index_bond(build(:bond, source_id: atom1.id, target_id: atom2.id))
      indexer.index_comment(build(:comment, parent_id: atom1.id))
    end

    it 'clears all indexes' do
      indexer.clear

      expect(indexer.atom_count).to eq(0)
      expect(indexer.bond_count).to eq(0)
      expect(indexer.all_comments).to be_empty
    end
  end

  describe '#rebuild' do
    let(:atoms) { [atom1, atom2] }
    let(:bonds) { [build(:bond, source_id: atom1.id, target_id: atom2.id)] }
    let(:comments) { [build(:comment, parent_id: atom1.id)] }

    it 'clears and rebuilds all indexes' do
      indexer.rebuild(atoms: atoms, bonds: bonds, comments: comments)

      expect(indexer.atom_count).to eq(2)
      expect(indexer.bond_count).to eq(1)
      expect(indexer.all_comments.length).to eq(1)
    end
  end
end
