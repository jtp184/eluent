# frozen_string_literal: true

module Eluent
  module Registry
    # Handles ID shortening, normalization, and disambiguation
    class IdResolver
      # Minimum prefix length for lookups
      MIN_PREFIX_LENGTH = 4

      # Confusable character mappings (Crockford Base32 spec)
      CONFUSABLES = { 'I' => '1', 'L' => '1', 'O' => '0', 'U' => 'V' }.freeze

      # Pattern for extracting repo prefix from input (e.g., "eluent-TSV4")
      REPO_PREFIX_PATTERN = /
        \A
        ([a-z][a-z0-9_-]*)   # repo name: starts with letter, followed by alphanumeric, underscore, or hyphen
        -                    # separator
        (.+)                 # the actual ID prefix
        \z
      /ix

      def initialize(indexer)
        @indexer = indexer
      end

      # Resolve a short or full ID to an atom
      # Returns: { atom: Atom } or { error: :not_found } or { error: :ambiguous, candidates: [...] }
      def resolve(input, repo_name: nil)
        input.to_s.strip.then do |clean_input|
          return error_result(:invalid_input, message: 'empty input') if clean_input.empty?
          return relative_reference_result(clean_input) if clean_input.start_with?('.')
          return resolve_full_id(clean_input) if IdGenerator.valid_atom_id?(clean_input)

          resolve_prefix(clean_input, repo_name:)
        end
      end

      # Get the short ID for display (minimum unique prefix)
      def short_id(atom)
        return nil unless atom&.id

        IdGenerator.extract_randomness(atom.id)&.then do |randomness|
          indexer.minimum_unique_prefix(randomness) || randomness[0, MIN_PREFIX_LENGTH]
        end
      end

      # Get display info for an atom
      def display_info(atom)
        return nil unless atom&.id

        IdGenerator.extract_ulid(atom.id)
                   &.then { |ulid| [ulid, IdGenerator.parse(ulid)] }
                   &.then { |ulid, parsed| build_display_info(atom, ulid, parsed) if parsed }
      end

      private

      attr_reader :indexer

      def resolve_full_id(input)
        indexer.find_by_id(input)
               &.then { |atom| { atom: } } || error_result(:not_found, id: input)
      end

      def resolve_prefix(input, repo_name:)
        repo_name, normalized = extract_repo_and_normalize(input, repo_name)

        return prefix_too_short_error if normalized.length < MIN_PREFIX_LENGTH

        resolve_candidates(input, normalized, repo_name)
      end

      def extract_repo_and_normalize(input, repo_name)
        if (match = input.match(REPO_PREFIX_PATTERN))
          [match[1].downcase, normalize_confusables(match[2])]
        else
          [repo_name, normalize_confusables(input)]
        end
      end

      def resolve_candidates(input, normalized, repo_name)
        indexer.find_by_randomness_prefix(normalized, repo: repo_name).then do |candidates|
          case candidates.length
          when 0 then error_result(:not_found, prefix: input)
          when 1 then { atom: candidates.first }
          else        ambiguous_result(input, candidates)
          end
        end
      end

      def normalize_confusables(input)
        CONFUSABLES.reduce(input.upcase) { |result, (from, to)| result.tr(from, to) }
      end

      def compute_minimum_prefixes(candidates)
        candidates.each_with_object({}) do |atom, prefixes|
          IdGenerator.extract_randomness(atom.id)&.then do |randomness|
            prefixes[atom.id] = indexer.minimum_unique_prefix(randomness) || randomness[0, MIN_PREFIX_LENGTH]
          end
        end
      end

      def build_display_info(atom, ulid, parsed)
        {
          full_id: atom.id,
          ulid:,
          timestamp: parsed[:timestamp],
          randomness: parsed[:randomness],
          created_time: parsed[:time],
          short: short_id(atom)
        }
      end

      # Result builders

      def error_result(type, **details)
        { error: type, **details }
      end

      def relative_reference_result(input)
        { error: :relative_reference, suffix: input[1..] }
      end

      def prefix_too_short_error
        error_result(:prefix_too_short, message: "minimum #{MIN_PREFIX_LENGTH} characters required for lookup")
      end

      def ambiguous_result(prefix, candidates)
        {
          error: :ambiguous,
          prefix:,
          candidates:,
          minimum_prefixes: compute_minimum_prefixes(candidates)
        }
      end
    end

    # Error when an ID prefix corresponds to multiple atoms
    class AmbiguousIdError < Error
      attr_reader :prefix, :candidates

      def initialize(prefix, candidates)
        @prefix = prefix
        @candidates = candidates

        super("Ambiguous ID '#{prefix}' matches #{candidates.length} items")
      end
    end

    # Error when an ID corresponds to no atoms
    class IdNotFoundError < Error
      attr_reader :id

      def initialize(id)
        @id = id

        super("Atom not found: #{id}")
      end
    end
  end
end
