# frozen_string_literal: true

require 'json'
require 'fileutils'

require_relative 'paths'
require_relative 'config_loader'
require_relative 'file_operations'
require_relative 'indexer'
require_relative 'serializers/atom_serializer'
require_relative 'serializers/bond_serializer'
require_relative '../models/atom'
require_relative '../models/bond'
require_relative '../models/comment'
require_relative '../registry/id_generator'
require_relative '../registry/id_resolver'

module Eluent
  module Storage
    # JSONL-based repository for atoms, bonds, and comments
    # Coordinates persistence, indexing, and ID resolution
    class JsonlRepository
      attr_reader :paths

      def initialize(root_path)
        @paths = Paths.new(root_path)
        @indexer = Indexer.new
        @config_loader = ConfigLoader.new(paths: paths)
        @id_resolver = nil
        @config = nil
        @loaded = false
      end

      # Initialize a new .eluent directory
      def init(repo_name: nil)
        raise RepositoryExistsError, paths.eluent_dir if Dir.exist?(paths.eluent_dir)

        create_directory_structure
        repo_name ||= RepoNameInferrer.new(paths).infer
        self.config = config_loader.write_initial(repo_name: repo_name)
        write_initial_data_file(repo_name)
        write_gitignore

        load!
        self
      end

      # Load repository data
      def load!
        raise RepositoryNotFoundError, paths.root unless paths.initialized?

        self.config = config_loader.load
        load_data_files
        self.id_resolver = Registry::IdResolver.new(@indexer)
        self.loaded = true
        self
      end

      def initialized? = paths.initialized?
      def loaded? = loaded
      def root_path = paths.root

      def id_resolver
        ensure_loaded!
        @id_resolver
      end

      def repo_name
        ensure_loaded!
        config['repo_name']
      end

      def indexer
        ensure_loaded!
        @indexer
      end

      # --- Atom Operations ---

      def create_atom(attrs = {})
        ensure_loaded!

        atom = build_atom(attrs.except(:ephemeral))
        atom = regenerate_id_if_collision(atom, attrs)

        target_file = attrs[:ephemeral] ? paths.ephemeral_file : paths.data_file

        FileOperations.append_record(target_file, Serializers::AtomSerializer.serialize(atom))
        indexer.index_atom(atom)
        atom
      end

      def update_atom(atom)
        ensure_loaded!
        atom.updated_at = Time.now.utc

        target_file = file_containing_atom(atom.id)

        FileOperations.rewrite_file(target_file) do |records|
          records.map do |record|
            record[:_type] == 'atom' && record[:id] == atom.id ? atom.to_h : record
          end
        end

        indexer.remove_atom(indexer.find_by_id(atom.id))
        indexer.index_atom(atom)
        atom
      end

      def find_atom(id)
        ensure_loaded!
        result = id_resolver.resolve(id, repo_name: repo_name)

        case result[:error]
        when nil then result[:atom]
        when :not_found then nil
        when :ambiguous then raise Registry::AmbiguousIdError.new(result[:prefix], result[:candidates])
        end
      end

      def find_atom_by_id(id)
        ensure_loaded!
        indexer.find_by_id(id)
      end

      def all_atoms
        ensure_loaded!
        indexer.all_atoms
      end

      def list_atoms(status: nil, issue_type: nil, assignee: nil, labels: nil, include_discarded: false)
        ensure_loaded!

        indexer.all_atoms
                .then { |atoms| include_discarded ? atoms : atoms.reject(&:discard?) }
                .then { |atoms| status ? atoms.select { |a| a.status == status } : atoms }
                .then { |atoms| issue_type ? atoms.select { |a| a.issue_type == issue_type } : atoms }
                .then { |atoms| assignee ? atoms.select { |a| a.assignee == assignee } : atoms }
                .then { |atoms| labels&.any? ? atoms.select { |a| (labels - a.labels).empty? } : atoms }
                .sort_by(&:created_at)
      end

      # --- Bond Operations ---

      def create_bond(source_id:, target_id:, dependency_type: 'blocks')
        ensure_loaded!

        bond = Models::Bond.new(source_id: source_id, target_id: target_id, dependency_type: dependency_type)

        existing = indexer.bonds_from(source_id).find { |b| b == bond }
        return existing if existing

        FileOperations.append_record(paths.data_file, Serializers::BondSerializer.serialize(bond))
        indexer.index_bond(bond)
        bond
      end

      def remove_bond(source_id:, target_id:, dependency_type:)
        ensure_loaded!

        bond = indexer.bonds_from(source_id).find do |b|
          b.target_id == target_id && b.dependency_type == dependency_type
        end
        return false unless bond

        FileOperations.rewrite_file(paths.data_file) do |records|
          records.reject do |record|
            record[:_type] == 'bond' &&
              record[:source_id] == source_id &&
              record[:target_id] == target_id &&
              record[:dependency_type] == dependency_type
          end
        end

        indexer.remove_bond(bond)
        true
      end

      def bonds_for(atom_id)
        ensure_loaded!
        { outgoing: indexer.bonds_from(atom_id), incoming: indexer.bonds_to(atom_id) }
      end

      # --- Comment Operations ---

      def create_comment(parent_id:, author:, content:)
        ensure_loaded!

        atom = find_atom_by_id(parent_id)
        raise Registry::IdNotFoundError, parent_id unless atom

        comment = build_comment(parent_id: parent_id, author: author, content: content)
        target_file = file_containing_atom(parent_id)

        FileOperations.append_record(target_file, Serializers::CommentSerializer.serialize(comment))
        indexer.index_comment(comment)
        comment
      end

      def comments_for(atom_id)
        ensure_loaded!
        indexer.comments_for(atom_id)
      end

      # --- Ephemeral Operations ---

      def persist_atom(atom_id)
        ensure_loaded!

        atom = find_atom_by_id(atom_id)
        raise Registry::IdNotFoundError, atom_id unless atom
        return false unless paths.ephemeral_exists?

        record = extract_record_from_ephemeral(atom_id)
        return false unless record

        FileOperations.append_record(paths.data_file, JSON.generate(record))
        true
      end

      private

      attr_accessor :config, :loaded
      attr_writer :id_resolver
      attr_reader :config_loader

      def ensure_loaded!
        raise RepositoryNotLoadedError unless loaded
      end

      # --- Initialization Helpers ---

      def create_directory_structure
        FileUtils.mkdir_p(paths.eluent_dir)
        FileUtils.mkdir_p(paths.formulas_dir)
        FileUtils.mkdir_p(paths.plugins_dir)
      end

      def write_initial_data_file(repo_name)
        header = {
          _type: 'header',
          repo_name: repo_name,
          generator: "eluent/#{Eluent::VERSION}",
          created_at: Time.now.utc.iso8601
        }
        File.write(paths.data_file, "#{JSON.generate(header)}\n")
      end

      def write_gitignore
        File.write(paths.gitignore_file, "ephemeral.jsonl\n.sync-state\n")
      end

      # --- Loading Helpers ---

      def load_data_files
        load_data_file(paths.data_file)
        load_data_file(paths.ephemeral_file) if paths.ephemeral_exists?
      end

      def load_data_file(path)
        FileOperations.each_record(path) do |data|
          index_record(data)
        end
      end

      def index_record(data)
        case data[:_type]
        when 'atom' then @indexer.index_atom(Serializers::AtomSerializer.deserialize(data))
        when 'bond' then @indexer.index_bond(Serializers::BondSerializer.deserialize(data))
        when 'comment' then @indexer.index_comment(Serializers::CommentSerializer.deserialize(data))
        end
      end

      # --- Atom Helpers ---

      def build_atom(attrs)
        attrs[:id] ||= Registry::IdGenerator.generate_atom_id(repo_name)
        attrs[:priority] ||= config.dig('defaults', 'priority') || 2
        attrs[:issue_type] ||= config.dig('defaults', 'issue_type') || 'task'
        Models::Atom.new(**attrs)
      end

      def regenerate_id_if_collision(atom, attrs)
        return atom unless indexer.atom_exists?(atom.id)

        attrs[:id] = Registry::IdGenerator.generate_atom_id(repo_name)
        Models::Atom.new(**attrs)
      end

      def file_containing_atom(atom_id)
        return paths.data_file unless paths.ephemeral_exists?

        in_ephemeral = FileOperations.record_exists?(paths.ephemeral_file) do |record|
          record[:_type] == 'atom' && record[:id] == atom_id
        end

        in_ephemeral ? paths.ephemeral_file : paths.data_file
      end

      # --- Comment Helpers ---

      def build_comment(parent_id:, author:, content:)
        existing_count = indexer.comments_for(parent_id).size
        comment_id = Registry::IdGenerator.generate_comment_id(atom_id: parent_id, index: existing_count + 1)

        Models::Comment.new(id: comment_id, parent_id: parent_id, author: author, content: content)
      end

      # --- Ephemeral Helpers ---

      def extract_record_from_ephemeral(atom_id)
        extracted = nil

        FileOperations.rewrite_file(paths.ephemeral_file) do |records|
          records.reject do |record|
            if record[:_type] == 'atom' && record[:id] == atom_id
              extracted = record
              true
            else
              false
            end
          end
        end

        extracted
      end
    end

    class RepositoryError < Error; end
    class RepositoryNotFoundError < RepositoryError; end
    class RepositoryExistsError < RepositoryError; end
    class RepositoryNotLoadedError < RepositoryError; end
  end
end
