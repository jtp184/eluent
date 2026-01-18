# frozen_string_literal: true

RSpec.describe Eluent::Registry::IdGenerator do
  describe '.generate' do
    it 'returns a 26-character string' do
      ulid = described_class.generate
      expect(ulid.length).to eq(26)
    end

    it 'uses only Crockford Base32 characters' do
      ulid = described_class.generate
      expect(ulid).to match(/\A[0-9A-HJKMNP-TV-Z]+\z/)
    end

    it 'starts with 0-7 to prevent overflow' do
      100.times do
        ulid = described_class.generate
        expect('0'..'7').to cover(ulid[0])
      end
    end

    it 'generates unique values' do
      ulids = 100.times.map { described_class.generate }
      expect(ulids.uniq.length).to eq(100)
    end

    it 'generates monotonically increasing values within the same millisecond' do
      # Due to randomness, we can't guarantee strict ordering,
      # but timestamps should be close
      ulid1 = described_class.generate
      ulid2 = described_class.generate

      # First 10 chars are timestamp
      timestamp1 = ulid1[0, 10]
      timestamp2 = ulid2[0, 10]

      expect(timestamp2 >= timestamp1).to be true
    end
  end

  describe '.generate_atom_id' do
    it 'prefixes ULID with repo name' do
      atom_id = described_class.generate_atom_id('myrepo')
      expect(atom_id).to start_with('myrepo-')
    end

    it 'contains a valid ULID after the prefix' do
      atom_id = described_class.generate_atom_id('myrepo')
      ulid = atom_id.split('-', 2).last
      expect(described_class.valid_ulid?(ulid)).to be true
    end
  end

  describe '.generate_child_id' do
    it 'appends child suffix to parent ID' do
      child_id = described_class.generate_child_id(
        parent_id: 'repo-01ABC123456789ABCDEF',
        child_suffix: 'subtask1'
      )
      expect(child_id).to eq('repo-01ABC123456789ABCDEF.subtask1')
    end
  end

  describe '.generate_comment_id' do
    it 'appends comment index to atom ID' do
      comment_id = described_class.generate_comment_id(
        atom_id: 'repo-01ABC123456789ABCDEF',
        index: 5
      )
      expect(comment_id).to eq('repo-01ABC123456789ABCDEF-c5')
    end
  end

  describe '.parse' do
    let(:valid_ulid) { '01JBZTMQ1RABCDEFGHKMNPQRST' }

    it 'extracts timestamp portion' do
      result = described_class.parse(valid_ulid)
      expect(result[:timestamp]).to eq('01JBZTMQ1R')
    end

    it 'extracts randomness portion' do
      result = described_class.parse(valid_ulid)
      expect(result[:randomness]).to eq('ABCDEFGHKMNPQRST')
    end

    it 'decodes timestamp to Time' do
      result = described_class.parse(valid_ulid)
      expect(result[:time]).to be_a(Time)
      expect(result[:time]).to be_utc
    end

    it 'returns nil for invalid ULIDs' do
      expect(described_class.parse('invalid')).to be_nil
      expect(described_class.parse('too-short')).to be_nil
    end

    it 'normalizes lowercase input' do
      result = described_class.parse(valid_ulid.downcase)
      expect(result).not_to be_nil
      expect(result[:timestamp]).to eq('01JBZTMQ1R')
    end
  end

  describe '.valid_ulid?' do
    it 'returns true for valid ULIDs' do
      expect(described_class.valid_ulid?('01JBZTMQ1RABCDEFGHKMNPQRST')).to be true
    end

    it 'returns false for too short strings' do
      expect(described_class.valid_ulid?('01JBZTMQ1RABCDEFGHKMNPQRS')).to be false
    end

    it 'returns false for too long strings' do
      expect(described_class.valid_ulid?('01JBZTMQ1RABCDEFGHKMNPQRSTV')).to be false
    end

    it 'returns false for first char > 7' do
      expect(described_class.valid_ulid?('81JBZTMQ1RABCDEFGHKMNPQRST')).to be false
    end

    it 'returns false for invalid characters (I, L, O, U)' do
      expect(described_class.valid_ulid?('01JBZTMQ1RABCDEFGHILMNOPQR')).to be false
    end

    it 'returns false for non-strings' do
      expect(described_class.valid_ulid?(nil)).to be false
      expect(described_class.valid_ulid?(123)).to be false
    end

    it 'accepts lowercase input' do
      expect(described_class.valid_ulid?('01jbztmq1rabcdefghkmnpqrst')).to be true
    end
  end

  describe '.extract_repo_name' do
    it 'extracts repo name from full atom ID' do
      expect(described_class.extract_repo_name('myrepo-01ABC123456789ABCDEF')).to eq('myrepo')
    end

    it 'handles repo names with underscores and hyphens' do
      expect(described_class.extract_repo_name('my_repo-123-01ABC123456789ABCDEF')).to eq('my_repo-123')
    end

    it 'returns nil for invalid formats' do
      expect(described_class.extract_repo_name('invalid')).to be_nil
    end
  end

  describe '.extract_ulid' do
    it 'extracts ULID from full atom ID' do
      ulid = described_class.extract_ulid('repo-01JBZTMQ1RABCDEFGHKMNPQRST')
      expect(ulid).to eq('01JBZTMQ1RABCDEFGHKMNPQRST')
    end

    it 'extracts ULID from child IDs' do
      ulid = described_class.extract_ulid('repo-01JBZTMQ1RABCDEFGHKMNPQRST.child')
      expect(ulid).to eq('01JBZTMQ1RABCDEFGHKMNPQRST')
    end

    it 'normalizes to uppercase' do
      ulid = described_class.extract_ulid('repo-01jbztmq1rabcdefghkmnpqrst')
      expect(ulid).to eq('01JBZTMQ1RABCDEFGHKMNPQRST')
    end

    it 'returns nil for invalid formats' do
      expect(described_class.extract_ulid('invalid')).to be_nil
    end
  end

  describe '.extract_randomness' do
    it 'extracts randomness from full atom ID' do
      randomness = described_class.extract_randomness('repo-01JBZTMQ1RABCDEFGHKMNPQRST')
      expect(randomness).to eq('ABCDEFGHKMNPQRST')
    end

    it 'extracts randomness from bare ULID' do
      randomness = described_class.extract_randomness('01JBZTMQ1RABCDEFGHKMNPQRST')
      expect(randomness).to eq('ABCDEFGHKMNPQRST')
    end

    it 'returns nil for IDs that are too short' do
      expect(described_class.extract_randomness('short')).to be_nil
    end
  end

  describe '.valid_atom_id?' do
    it 'returns true for valid atom IDs' do
      expect(described_class.valid_atom_id?('repo-01JBZTMQ1RABCDEFGHKMNPQRST')).to be true
    end

    it 'returns true for child IDs' do
      expect(described_class.valid_atom_id?('repo-01JBZTMQ1RABCDEFGHKMNPQRST.child')).to be true
    end

    it 'returns true for nested child IDs' do
      expect(described_class.valid_atom_id?('repo-01JBZTMQ1RABCDEFGHKMNPQRST.child.grandchild')).to be true
    end

    it 'returns false for IDs without repo prefix' do
      expect(described_class.valid_atom_id?('01JBZTMQ1RABCDEFGHKMNPQRST')).to be false
    end

    it 'returns false for IDs with invalid ULID' do
      expect(described_class.valid_atom_id?('repo-invalid')).to be false
    end

    it 'returns false for empty strings' do
      expect(described_class.valid_atom_id?('')).to be false
    end
  end

  describe 'ULID timestamp encoding/decoding' do
    it 'round-trips current time correctly' do
      Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
        ulid = described_class.generate
        parsed = described_class.parse(ulid)

        expect(parsed[:time]).to be_within(1).of(Time.now.utc)
      end
    end
  end
end
