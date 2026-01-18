# frozen_string_literal: true

require 'securerandom'

module Eluent
  module Registry
    # ULID generation using Crockford Base32 encoding
    # Format: 26 characters (10 timestamp + 16 random)
    # Charset: 0-9, A-H, J-K, M-N, P, R-T, V-Z (excludes I, L, O, U)
    class IdGenerator
      # Crockford Base32 encoding alphabet
      ENCODING = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
      ENCODING_LENGTH = ENCODING.length

      # ULID specifications
      TIMESTAMP_LENGTH = 10
      RANDOMNESS_LENGTH = 16
      ULID_LENGTH = TIMESTAMP_LENGTH + RANDOMNESS_LENGTH

      # Maximum timestamp (year 10889)
      MAX_TIMESTAMP = (2**48) - 1

      # Regex patterns for ID parsing and validation
      REPO_NAME_PATTERN = /\A([a-z][a-z0-9_-]{0,31})-/
      ULID_EXTRACT_PATTERN = /-([0-7][0-9A-HJKMNP-TV-Z]{25})(?:\.|\z)/i
      ATOM_ID_PATTERN = /
        \A
        (?<repo>[a-z][a-z0-9_-]{0,31})        # repo name: lowercase start, alphanumeric underscore hyphen
        -                                     # separator
        (?<ulid>[0-7][0-9A-HJKMNP-TV-Z]{25})  # ULID: first char 0-7, then 25 Crockford Base32 chars
        (?:
          \.                                  # child separator
          (?<children>[a-zA-Z0-9_-]+          # first child segment
            (?:\.[a-zA-Z0-9_-]+)*)            # additional child segments
        )?
        \z
      /ix

      class << self
        # Generate a new ULID
        def generate
          "#{encode_timestamp(current_time_ms)}#{encode_randomness}"
        end

        # Generate a full atom ID with repo prefix
        def generate_atom_id(repo_name)
          "#{repo_name}-#{generate}"
        end

        # Generate a child ID
        def generate_child_id(parent_id:, child_suffix:)
          "#{parent_id}.#{child_suffix}"
        end

        # Generate a comment ID
        def generate_comment_id(atom_id:, index:)
          "#{atom_id}-c#{index}"
        end

        # Parse a ULID to extract timestamp and randomness
        def parse(ulid)
          ulid.to_s.upcase.then do |normalized|
            return nil unless valid_ulid?(normalized)

            {
              timestamp: normalized[0, TIMESTAMP_LENGTH],
              randomness: normalized[TIMESTAMP_LENGTH, RANDOMNESS_LENGTH],
              time: decode_timestamp(normalized[0, TIMESTAMP_LENGTH])
            }
          end
        end

        # Check if a string is a valid ULID
        def valid_ulid?(ulid)
          return false unless ulid.is_a?(String) && ulid.length == ULID_LENGTH

          ulid.upcase.then do |normalized|
            # First character must be 0-7 to prevent overflow
            ('0'..'7').cover?(normalized[0]) && normalized.chars.all? { |c| ENCODING.include?(c) }
          end
        end

        # Extract repo name from full ID
        def extract_repo_name(full_id)
          full_id.match(REPO_NAME_PATTERN)&.[](1)
        end

        # Extract ULID from full ID
        def extract_ulid(full_id)
          # Pattern: repo-ULID or repo-ULID.child...
          full_id.match(ULID_EXTRACT_PATTERN)&.[](1)&.upcase
        end

        # Extract randomness portion from ULID or full ID
        def extract_randomness(id)
          ulid = extract_ulid(id) || id.upcase
          return nil unless ulid.length >= ULID_LENGTH

          ulid[TIMESTAMP_LENGTH, RANDOMNESS_LENGTH]
        end

        # Validate full atom ID format
        def valid_atom_id?(id)
          ATOM_ID_PATTERN.match?(id)
        end

        private

        def current_time_ms
          (Time.now.to_f * 1000).to_i
        end

        def encode_timestamp(time_ms)
          raise ArgumentError, 'timestamp exceeds maximum' if time_ms > MAX_TIMESTAMP

          encode_base32(time_ms, TIMESTAMP_LENGTH)
        end

        def encode_randomness
          # Generate 80 bits of randomness (10 bytes)
          random_bytes = SecureRandom.random_bytes(10)
          random_value = (random_bytes.unpack1('Q>') << 16) | random_bytes[8..9].unpack1('n')
          encode_base32(random_value, RANDOMNESS_LENGTH)
        end

        def encode_base32(value, length)
          ''.tap do |result|
            length.times do
              result.prepend(ENCODING[value % ENCODING_LENGTH])
              value /= ENCODING_LENGTH
            end
          end
        end

        def decode_timestamp(timestamp_str)
          0.then do |value|
            timestamp_str.each_char do |char|
              value *= (ENCODING_LENGTH + ENCODING.index(char.upcase))
            end

            Time.at(value / 1000.0).utc
          end
        end
      end
    end
  end
end
