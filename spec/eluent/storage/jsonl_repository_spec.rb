# frozen_string_literal: true

require 'tempfile'
require 'fileutils'

RSpec.describe Eluent::Storage::JsonlRepository do
  let(:temp_dir) { Dir.mktmpdir }
  let(:root_path) { temp_dir }
  let(:repository) { described_class.new(root_path) }
  let(:paths) { repository.paths }

  after { FileUtils.rm_rf(temp_dir) }

  def read_jsonl_records(path)
    return [] unless File.exist?(path)

    File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }
  end

  describe '#init' do
    it 'creates the .eluent directory structure' do
      repository.init(repo_name: 'test')

      expect(Dir.exist?(paths.eluent_dir)).to be true
      expect(Dir.exist?(paths.formulas_dir)).to be true
      expect(Dir.exist?(paths.plugins_dir)).to be true
    end

    it 'creates the data file with header' do
      repository.init(repo_name: 'test')

      expect(File.exist?(paths.data_file)).to be true
      records = read_jsonl_records(paths.data_file)
      expect(records.first[:_type]).to eq('header')
    end

    it 'creates the config file' do
      repository.init(repo_name: 'test')

      expect(File.exist?(paths.config_file)).to be true
    end

    it 'creates the .gitignore file' do
      repository.init(repo_name: 'test')

      expect(File.exist?(paths.gitignore_file)).to be true
      content = File.read(paths.gitignore_file)
      expect(content).to include('ephemeral.jsonl')
    end

    it 'loads the repository after init' do
      repository.init(repo_name: 'test')

      expect(repository).to be_loaded
    end

    it 'raises error if already initialized' do
      repository.init(repo_name: 'test')
      new_repo = described_class.new(root_path)

      expect { new_repo.init(repo_name: 'test') }
        .to raise_error(Eluent::Storage::RepositoryExistsError)
    end
  end

  describe '#load!' do
    before { repository.init(repo_name: 'test') }

    it 'marks repository as loaded' do
      new_repo = described_class.new(root_path)
      new_repo.load!

      expect(new_repo).to be_loaded
    end

    it 'raises error if not initialized' do
      FileUtils.rm_rf(paths.eluent_dir)
      new_repo = described_class.new(root_path)

      expect { new_repo.load! }.to raise_error(Eluent::Storage::RepositoryNotFoundError)
    end

    it 'loads atoms from data file' do
      repository.create_atom(title: 'Test')
      new_repo = described_class.new(root_path)
      new_repo.load!

      expect(new_repo.all_atoms).not_to be_empty
    end
  end

  describe '#repo_name' do
    before { repository.init(repo_name: 'myrepo') }

    it 'returns the configured repo name' do
      expect(repository.repo_name).to eq('myrepo')
    end
  end

  describe 'atom operations' do
    before { repository.init(repo_name: 'test') }

    describe '#create_atom' do
      it 'creates an atom with generated ID' do
        atom = repository.create_atom(title: 'Test Atom')

        expect(atom).to be_a(Eluent::Models::Atom)
        expect(atom.id).to start_with('test-')
      end

      it 'persists the atom to data file' do
        atom = repository.create_atom(title: 'Test Atom')

        records = read_jsonl_records(paths.data_file)
        atom_records = records.select { |r| r[:_type] == 'atom' }
        expect(atom_records.map { |r| r[:id] }).to include(atom.id)
      end

      it 'indexes the atom' do
        atom = repository.create_atom(title: 'Test Atom')

        expect(repository.find_atom_by_id(atom.id)).to eq(atom)
      end

      it 'accepts custom attributes' do
        atom = repository.create_atom(
          title: 'Bug Fix',
          issue_type: :bug,
          priority: 1,
          labels: ['urgent']
        )

        expect(atom.issue_type).to eq(Eluent::Models::IssueType[:bug])
        expect(atom.priority).to eq(1)
        expect(atom.labels).to include('urgent')
      end

      it 'handles ID collisions by regenerating' do
        first_atom = repository.create_atom(title: 'First')
        expect(first_atom.id).not_to be_nil
      end
    end

    describe '#update_atom' do
      let(:atom) { repository.create_atom(title: 'Original') }

      it 'updates atom attributes' do
        atom.title = 'Updated'
        updated = repository.update_atom(atom)

        expect(updated.title).to eq('Updated')
      end

      it 'updates the updated_at timestamp' do
        original_time = atom.updated_at
        sleep 0.01

        repository.update_atom(atom)

        expect(atom.updated_at).to be > original_time
      end

      it 'persists changes to data file' do
        atom.title = 'Changed'
        repository.update_atom(atom)

        new_repo = described_class.new(root_path)
        new_repo.load!

        reloaded = new_repo.find_atom_by_id(atom.id)
        expect(reloaded.title).to eq('Changed')
      end
    end

    describe '#find_atom' do
      let!(:atom) { repository.create_atom(title: 'Findable') }

      it 'finds by full ID' do
        found = repository.find_atom(atom.id)
        expect(found).to eq(atom)
      end

      it 'finds by prefix' do
        randomness = Eluent::Registry::IdGenerator.extract_randomness(atom.id)
        prefix = randomness[0, 6]

        found = repository.find_atom(prefix)
        expect(found).to eq(atom)
      end

      it 'returns nil for non-existent ID' do
        found = repository.find_atom('test-01NONEXISTENT123456789')
        expect(found).to be_nil
      end
    end

    describe '#list_atoms' do
      before do
        repository.create_atom(title: 'Open Task', status: :open, issue_type: :task)
        repository.create_atom(title: 'Closed Bug', status: :closed, issue_type: :bug)
        repository.create_atom(title: 'Blocked Feature', status: :blocked, issue_type: :feature)
      end

      it 'returns all atoms' do
        atoms = repository.list_atoms
        expect(atoms.length).to eq(3)
      end

      it 'filters by status' do
        atoms = repository.list_atoms(status: Eluent::Models::Status[:open])
        expect(atoms.length).to eq(1)
        expect(atoms.first.title).to eq('Open Task')
      end

      it 'filters by issue_type' do
        atoms = repository.list_atoms(issue_type: Eluent::Models::IssueType[:bug])
        expect(atoms.length).to eq(1)
        expect(atoms.first.title).to eq('Closed Bug')
      end

      it 'excludes discarded atoms by default' do
        discarded = repository.create_atom(title: 'Discarded', status: :discard)
        atoms = repository.list_atoms

        expect(atoms).not_to include(discarded)
      end

      it 'includes discarded atoms when requested' do
        discarded = repository.create_atom(title: 'Discarded', status: :discard)
        atoms = repository.list_atoms(include_discarded: true)

        expect(atoms).to include(discarded)
      end

      it 'sorts by created_at' do
        atoms = repository.list_atoms
        created_times = atoms.map(&:created_at)

        expect(created_times).to eq(created_times.sort)
      end
    end
  end

  describe 'bond operations' do
    before { repository.init(repo_name: 'test') }

    let(:atom1) { repository.create_atom(title: 'Source') }
    let(:atom2) { repository.create_atom(title: 'Target') }

    describe '#create_bond' do
      it 'creates a bond between atoms' do
        bond = repository.create_bond(
          source_id: atom1.id,
          target_id: atom2.id,
          dependency_type: 'blocks'
        )

        expect(bond).to be_a(Eluent::Models::Bond)
        expect(bond.source_id).to eq(atom1.id)
        expect(bond.target_id).to eq(atom2.id)
      end

      it 'persists the bond to data file' do
        repository.create_bond(
          source_id: atom1.id,
          target_id: atom2.id
        )

        records = read_jsonl_records(paths.data_file)
        bond_records = records.select { |r| r[:_type] == 'bond' }
        expect(bond_records).not_to be_empty
      end

      it 'returns existing bond if duplicate' do
        bond1 = repository.create_bond(
          source_id: atom1.id,
          target_id: atom2.id,
          dependency_type: 'blocks'
        )
        bond2 = repository.create_bond(
          source_id: atom1.id,
          target_id: atom2.id,
          dependency_type: 'blocks'
        )

        expect(bond1).to eq(bond2)
      end
    end

    describe '#remove_bond' do
      before do
        repository.create_bond(
          source_id: atom1.id,
          target_id: atom2.id,
          dependency_type: 'blocks'
        )
      end

      it 'removes the bond' do
        result = repository.remove_bond(
          source_id: atom1.id,
          target_id: atom2.id,
          dependency_type: Eluent::Models::DependencyType[:blocks]
        )

        expect(result).to be true
      end

      it 'returns false for non-existent bond' do
        result = repository.remove_bond(
          source_id: atom1.id,
          target_id: atom2.id,
          dependency_type: Eluent::Models::DependencyType[:related]
        )

        expect(result).to be false
      end
    end

    describe '#bonds_for' do
      before do
        repository.create_bond(source_id: atom1.id, target_id: atom2.id)
      end

      it 'returns outgoing bonds' do
        bonds = repository.bonds_for(atom1.id)
        expect(bonds[:outgoing]).not_to be_empty
      end

      it 'returns incoming bonds' do
        bonds = repository.bonds_for(atom2.id)
        expect(bonds[:incoming]).not_to be_empty
      end
    end
  end

  describe 'comment operations' do
    before { repository.init(repo_name: 'test') }

    let(:atom) { repository.create_atom(title: 'Commentable') }

    describe '#create_comment' do
      it 'creates a comment on an atom' do
        comment = repository.create_comment(
          parent_id: atom.id,
          author: 'user',
          content: 'Test comment'
        )

        expect(comment).to be_a(Eluent::Models::Comment)
        expect(comment.parent_id).to eq(atom.id)
      end

      it 'generates sequential comment IDs' do
        comment1 = repository.create_comment(parent_id: atom.id, author: 'user', content: 'First')
        comment2 = repository.create_comment(parent_id: atom.id, author: 'user', content: 'Second')

        expect(comment1.id).to end_with('-c1')
        expect(comment2.id).to end_with('-c2')
      end

      it 'raises error for non-existent parent' do
        expect do
          repository.create_comment(
            parent_id: 'nonexistent',
            author: 'user',
            content: 'Test'
          )
        end.to raise_error(Eluent::Registry::IdNotFoundError)
      end
    end

    describe '#comments_for' do
      before do
        repository.create_comment(parent_id: atom.id, author: 'user1', content: 'Comment 1')
        repository.create_comment(parent_id: atom.id, author: 'user2', content: 'Comment 2')
      end

      it 'returns comments for the atom' do
        comments = repository.comments_for(atom.id)
        expect(comments.length).to eq(2)
      end

      it 'returns comments sorted by created_at' do
        comments = repository.comments_for(atom.id)
        created_times = comments.map(&:created_at)
        expect(created_times).to eq(created_times.sort)
      end
    end
  end

  describe 'ensure_loaded!' do
    it 'raises error when accessing methods before loading' do
      new_repo = described_class.new(root_path)

      expect { new_repo.all_atoms }.to raise_error(Eluent::Storage::RepositoryNotLoadedError)
    end
  end
end
