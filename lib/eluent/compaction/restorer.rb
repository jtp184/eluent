# frozen_string_literal: true

require 'json'

module Eluent
  module Compaction
    # Raised when restoration of a compacted atom fails
    class RestoreError < Error
      attr_reader :atom_id

      def initialize(message, atom_id: nil)
        @atom_id = atom_id
        super(message)
      end
    end

    # Restores compacted atoms from git history
    class Restorer
      def initialize(repository:, git_adapter: nil)
        @repository = repository
        @git_adapter = git_adapter || Sync::GitAdapter.new(repo_path: repository.paths.root)
      end

      # Restores a compacted atom from git history.
      #
      # Note on atomicity: This operation is NOT atomic. If interrupted mid-operation,
      # the atom's description may be restored while comments are not (or vice versa).
      # However, this is recoverable: simply re-run restore to complete the restoration.
      # The 'restored_at' metadata is set at the end, so partial restores can be detected.
      def restore(atom_id)
        atom = repository.find_atom(atom_id)
        raise Registry::IdNotFoundError, atom_id unless atom

        raise RestoreError.new('Atom has not been compacted', atom_id: atom_id) unless compacted?(atom)

        historical_data = find_historical_version(atom)
        unless historical_data
          raise RestoreError.new('Could not find pre-compaction version in git history',
                                 atom_id: atom_id)
        end

        apply_restoration(atom, historical_data)

        RestorationResult.new(
          atom_id: atom.id,
          restored_description_length: atom.description&.length || 0,
          restored_comment_count: historical_data[:comments]&.size || 0
        )
      end

      def can_restore?(atom_id)
        atom = repository.find_atom(atom_id)
        return false unless atom
        return false unless compacted?(atom)

        !find_historical_version(atom).nil?
      rescue StandardError
        false
      end

      def preview_restore(atom_id)
        atom = repository.find_atom(atom_id)
        raise Registry::IdNotFoundError, atom_id unless atom

        raise RestoreError.new('Atom has not been compacted', atom_id: atom_id) unless compacted?(atom)

        historical_data = find_historical_version(atom)
        unless historical_data
          raise RestoreError.new('Could not find pre-compaction version in git history',
                                 atom_id: atom_id)
        end

        {
          atom_id: atom.id,
          current: {
            description_length: atom.description&.length || 0,
            comment_count: repository.comments_for(atom.id).size,
            compaction_tier: atom.metadata&.dig('compaction_tier')
          },
          restored: {
            description_length: historical_data[:description]&.length || 0,
            comment_count: historical_data[:comments]&.size || 0
          },
          commit: historical_data[:commit]
        }
      end

      private

      attr_reader :repository, :git_adapter

      def compacted?(atom)
        atom.metadata&.dig('compaction_tier')&.positive?
      end

      def find_historical_version(atom)
        compacted_at = atom.metadata&.dig('compacted_at')
        return nil unless compacted_at

        # Search git history for the data file before compaction
        data_file_relative = File.join(
          Storage::Paths::ELUENT_DIR,
          Storage::Paths::DATA_FILE
        )
        commits = find_commits_before(compacted_at, data_file_relative)

        commits.each do |commit|
          historical_content = git_show_file(commit, data_file_relative)
          next unless historical_content

          atom_data, comments = extract_atom_data(historical_content, atom.id)
          next unless atom_data
          next if already_compacted?(atom_data)

          return {
            commit: commit,
            description: atom_data[:description],
            comments: comments,
            atom_data: atom_data
          }
        end

        nil
      end

      def find_commits_before(timestamp, file_path)
        # Get commits that modified the file before the given timestamp
        result = git_adapter.run_git(
          'log',
          '--format=%H',
          "--until=#{timestamp}",
          '-n', '20',
          '--',
          file_path
        )

        return [] unless result[:success]

        result[:output].split("\n").map(&:strip).reject(&:empty?)
      rescue StandardError
        []
      end

      def git_show_file(commit, file_path)
        result = git_adapter.run_git('show', "#{commit}:#{file_path}")
        return nil unless result[:success]

        result[:output]
      rescue StandardError
        nil
      end

      def extract_atom_data(content, atom_id)
        atom_data = nil
        comments = []

        content.each_line do |line|
          next if line.strip.empty?

          begin
            record = JSON.parse(line, symbolize_names: true)

            case record[:_type]
            when 'atom'
              # Use first match (chronologically earlier in file is canonical)
              atom_data ||= record if record[:id] == atom_id
            when 'comment'
              comments << record if record[:parent_id] == atom_id
            end
          rescue JSON::ParserError
            next
          end
        end

        [atom_data, comments]
      end

      def already_compacted?(atom_data)
        atom_data.dig(:metadata, :compaction_tier)&.positive?
      end

      def apply_restoration(atom, historical_data)
        # Restore description
        atom.description = historical_data[:description]

        # Clear compaction metadata
        atom.metadata ||= {}
        atom.metadata.delete('compaction_tier')
        atom.metadata.delete('compacted_at')
        atom.metadata.delete('original_description_length')
        atom.metadata.delete('original_comment_count')
        atom.metadata['restored_at'] = Time.now.utc.iso8601
        atom.metadata['restored_from_commit'] = historical_data[:commit]

        repository.update_atom(atom)

        # Restore comments
        restore_comments(atom.id, historical_data[:comments])
      end

      def restore_comments(atom_id, historical_comments)
        # First, remove any compacted summary comments
        repository.compact_comments(atom_id, nil)

        # Re-create historical comments
        historical_comments.each do |comment_data|
          repository.create_comment(
            parent_id: atom_id,
            author: comment_data[:author] || 'restored',
            content: comment_data[:content] || '[restored]'
          )
        end
      end
    end

    # Result of restoring a compacted atom
    class RestorationResult
      attr_reader :atom_id, :restored_description_length, :restored_comment_count

      def initialize(atom_id:, restored_description_length:, restored_comment_count:)
        @atom_id = atom_id
        @restored_description_length = restored_description_length
        @restored_comment_count = restored_comment_count
      end

      def to_h
        {
          atom_id: atom_id,
          restored_description_length: restored_description_length,
          restored_comment_count: restored_comment_count
        }
      end
    end
  end
end
