# frozen_string_literal: true

# Helpers for predictable test ID generation
module IdHelper
  # Fixed ULID timestamp portion (represents a fixed point in time)
  FIXED_TIMESTAMP = '01JBZTMQ1R'

  # Standard repo name for tests
  TEST_REPO = 'testrepo'

  # Generate a predictable test atom ID
  def test_atom_id(suffix = 'ABCDEFGHKMNPQRST')
    "#{TEST_REPO}-#{FIXED_TIMESTAMP}#{suffix}"
  end

  # Generate a predictable test atom ID with custom repo
  def test_atom_id_for_repo(repo, suffix = 'ABCDEFGHKMNPQRST')
    "#{repo}-#{FIXED_TIMESTAMP}#{suffix}"
  end

  # Generate a sequence of test IDs
  def test_atom_ids(count)
    suffixes = ('A'..'Z').to_a + ('0'..'9').to_a
    (0...count).map do |i|
      char = suffixes[i % suffixes.size]
      test_atom_id("#{char * 16}")
    end
  end

  # Valid ULID for parsing tests
  def valid_ulid
    "#{FIXED_TIMESTAMP}ABCDEFGHKMNPQRST"
  end

  # Invalid ULIDs for negative tests
  def invalid_ulids
    [
      '01JBZTMQ1RABCDEFGHKMNPQRS',     # Too short (25 chars)
      '01JBZTMQ1RABCDEFGHKMNPQRSTV',   # Too long (27 chars)
      '81JBZTMQ1RABCDEFGHKMNPQRST',    # First char > 7
      '01JBZTMQ1RABCDEFGHILMNOPQR',    # Contains I, L, O
      ''
    ]
  end

  # Standard test comment ID
  def test_comment_id(atom_id = test_atom_id, index = 1)
    "#{atom_id}-c#{index}"
  end
end

RSpec.configure do |config|
  config.include IdHelper
end
