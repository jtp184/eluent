# frozen_string_literal: true

require_relative 'prefix_trie'
require_relative '../registry/id_generator'

module Eluent
  module Storage
    # Dual-index for efficient ID lookups
    # - Exact index: Hash map for O(1) full ID lookup
    # - Randomness prefix trie: Per-repo trie indexed by last 16 chars of ULID
    class Indexer
      def initialize
        @exact_index = {}
        @randomness_tries = Hash.new { |h, k| h[k] = PrefixTrie.new }
        @bonds_by_source = Hash.new { |h, k| h[k] = [] }
        @bonds_by_target = Hash.new { |h, k| h[k] = [] }
        @comments_by_parent = Hash.new { |h, k| h[k] = [] }
      end

      def index_atom(atom)
        return unless atom&.id

        exact_index[atom.id] = atom
        index_atom_in_trie(atom)
      end

      def remove_atom(atom)
        return unless atom&.id

        exact_index.delete(atom.id)
        remove_atom_from_trie(atom)
      end

      def index_bond(bond)
        return unless bond

        add_to_collection(bonds_by_source[bond.source_id], bond)
        add_to_collection(bonds_by_target[bond.target_id], bond)
      end

      def remove_bond(bond)
        return unless bond

        bonds_by_source[bond.source_id].delete(bond)
        bonds_by_target[bond.target_id].delete(bond)
      end

      def index_comment(comment)
        return unless comment&.parent_id

        add_to_collection(comments_by_parent[comment.parent_id], comment)
      end

      def remove_comment(comment)
        return unless comment&.parent_id

        comments_by_parent[comment.parent_id].delete(comment)
      end

      def find_by_id(id)
        exact_index[id]
      end

      def find_by_randomness_prefix(prefix, repo: nil)
        normalized = prefix.to_s.upcase
        if repo
          randomness_tries[repo].prefix_match(normalized)
        else
          randomness_tries.values.flat_map { |trie| trie.prefix_match(normalized) }
        end
      end

      def minimum_unique_prefix(randomness)
        randomness_tries.values.lazy
                        .map { |trie| trie.minimum_unique_prefix(randomness) }
                        .find(&:itself)
      end

      def all_atoms
        exact_index.values
      end

      def atoms_by_status(status)
        all_atoms.select { |atom| atom.status == status }
      end

      def atoms_by_type(issue_type)
        all_atoms.select { |atom| atom.issue_type == issue_type }
      end

      def children_of(parent_id)
        all_atoms.select { |atom| atom.parent_id == parent_id }
      end

      def bonds_from(atom_id)
        bonds_by_source[atom_id].dup
      end

      def bonds_to(atom_id)
        bonds_by_target[atom_id].dup
      end

      def all_bonds
        bonds_by_source.values.flatten.uniq
      end

      def comments_for(atom_id)
        comments_by_parent[atom_id].sort_by(&:created_at)
      end

      def all_comments
        comments_by_parent.values.flatten
      end

      def atom_exists?(id)
        exact_index.key?(id)
      end

      def atom_count
        exact_index.size
      end

      def bond_count
        all_bonds.size
      end

      def clear
        [exact_index, randomness_tries, bonds_by_source, bonds_by_target, comments_by_parent].each(&:clear)
      end

      def rebuild(atoms: [], bonds: [], comments: [])
        clear
        atoms.each { |atom| index_atom(atom) }
        bonds.each { |bond| index_bond(bond) }
        comments.each { |comment| index_comment(comment) }
      end

      private

      attr_reader :exact_index, :randomness_tries, :bonds_by_source, :bonds_by_target, :comments_by_parent

      def index_atom_in_trie(atom)
        with_atom_id_parts(atom.id) do |repo, randomness|
          randomness_tries[repo].insert(randomness, atom)
        end
      end

      def remove_atom_from_trie(atom)
        with_atom_id_parts(atom.id) do |repo, randomness|
          randomness_tries[repo].delete(randomness, atom)
        end
      end

      def with_atom_id_parts(id)
        repo = Registry::IdGenerator.extract_repo_name(id)
        randomness = Registry::IdGenerator.extract_randomness(id)
        yield(repo, randomness) if repo && randomness
      end

      def add_to_collection(collection, item)
        collection << item unless collection.include?(item)
      end
    end
  end
end
