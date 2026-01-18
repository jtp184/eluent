# frozen_string_literal: true

RSpec.describe Eluent::Storage::PrefixTrie do
  subject(:trie) { described_class.new }

  describe '#initialize' do
    it 'starts empty' do
      expect(trie).to be_empty
      expect(trie.count).to eq(0)
    end
  end

  describe '#insert' do
    it 'adds a value to the trie' do
      trie.insert('ABCD', 'value1')
      expect(trie.count).to eq(1)
    end

    it 'allows multiple values for the same key' do
      trie.insert('ABCD', 'value1')
      trie.insert('ABCD', 'value2')
      expect(trie.count).to eq(2)
    end

    it 'does not add duplicate values for the same key' do
      trie.insert('ABCD', 'value1')
      trie.insert('ABCD', 'value1')
      expect(trie.count).to eq(1)
    end

    it 'normalizes keys to uppercase' do
      trie.insert('abcd', 'value1')
      expect(trie.exact_match('ABCD')).to contain_exactly('value1')
    end
  end

  describe '#delete' do
    before do
      trie.insert('ABCD', 'value1')
      trie.insert('ABCD', 'value2')
    end

    it 'removes a specific value' do
      trie.delete('ABCD', 'value1')
      expect(trie.exact_match('ABCD')).to contain_exactly('value2')
    end

    it 'decrements the count' do
      trie.delete('ABCD', 'value1')
      expect(trie.count).to eq(1)
    end

    it 'returns nil for non-existent values' do
      result = trie.delete('ABCD', 'nonexistent')
      expect(result).to be_nil
    end

    it 'returns nil for non-existent keys' do
      result = trie.delete('XXXX', 'value1')
      expect(result).to be_nil
    end
  end

  describe '#prefix_match' do
    before do
      trie.insert('ABCD1234', 'value1')
      trie.insert('ABCD5678', 'value2')
      trie.insert('ABEF1234', 'value3')
      trie.insert('WXYZ9999', 'value4')
    end

    it 'returns all values matching a prefix' do
      results = trie.prefix_match('ABCD')
      expect(results).to contain_exactly('value1', 'value2')
    end

    it 'returns values for shorter prefixes' do
      results = trie.prefix_match('AB')
      expect(results).to contain_exactly('value1', 'value2', 'value3')
    end

    it 'returns exact matches for full keys' do
      results = trie.prefix_match('ABCD1234')
      expect(results).to contain_exactly('value1')
    end

    it 'returns empty array for non-matching prefix' do
      results = trie.prefix_match('ZZZZ')
      expect(results).to be_empty
    end

    it 'normalizes prefix to uppercase' do
      results = trie.prefix_match('abcd')
      expect(results).to contain_exactly('value1', 'value2')
    end
  end

  describe '#prefix_exists?' do
    before do
      trie.insert('ABCD1234', 'value1')
    end

    it 'returns true for existing prefixes' do
      expect(trie.prefix_exists?('ABCD')).to be true
      expect(trie.prefix_exists?('AB')).to be true
      expect(trie.prefix_exists?('A')).to be true
    end

    it 'returns true for full keys' do
      expect(trie.prefix_exists?('ABCD1234')).to be true
    end

    it 'returns false for non-existent prefixes' do
      expect(trie.prefix_exists?('ZZZZ')).to be false
    end
  end

  describe '#exact_match' do
    before do
      trie.insert('ABCD', 'value1')
      trie.insert('ABCD', 'value2')
      trie.insert('ABCD1234', 'value3')
    end

    it 'returns only values at the exact key' do
      results = trie.exact_match('ABCD')
      expect(results).to contain_exactly('value1', 'value2')
    end

    it 'does not return child values' do
      results = trie.exact_match('ABCD')
      expect(results).not_to include('value3')
    end

    it 'returns empty array for non-existent keys' do
      results = trie.exact_match('XXXX')
      expect(results).to be_empty
    end
  end

  describe '#minimum_unique_prefix' do
    context 'with unique values' do
      before do
        trie.insert('ABCD1234EFGH5678', 'value1')
        trie.insert('WXYZ1234EFGH5678', 'value2')
      end

      it 'returns the minimum unique prefix' do
        expect(trie.minimum_unique_prefix('ABCD1234EFGH5678')).to eq('ABCD')
        expect(trie.minimum_unique_prefix('WXYZ1234EFGH5678')).to eq('WXYZ')
      end
    end

    context 'with overlapping prefixes' do
      before do
        trie.insert('ABCD1234', 'value1')
        trie.insert('ABCD5678', 'value2')
      end

      it 'returns a longer prefix to disambiguate' do
        prefix1 = trie.minimum_unique_prefix('ABCD1234')
        prefix2 = trie.minimum_unique_prefix('ABCD5678')

        expect(prefix1.length).to be > 4
        expect(prefix2.length).to be > 4
        expect(prefix1).not_to eq(prefix2)
      end
    end

    it 'returns nil for keys shorter than minimum length' do
      trie.insert('ABC', 'value')
      expect(trie.minimum_unique_prefix('ABC')).to be_nil
    end

    it 'returns the full key if no unique prefix exists within the key' do
      trie.insert('ABCD1234', 'value1')
      trie.insert('ABCD1234', 'value2')

      expect(trie.minimum_unique_prefix('ABCD1234')).to eq('ABCD1234')
    end
  end

  describe '#clear' do
    before do
      trie.insert('ABCD', 'value1')
      trie.insert('EFGH', 'value2')
    end

    it 'removes all values' do
      trie.clear
      expect(trie).to be_empty
      expect(trie.count).to eq(0)
    end

    it 'clears all prefix matches' do
      trie.clear
      expect(trie.prefix_match('ABCD')).to be_empty
    end
  end

  describe '#empty?' do
    it 'returns true for a new trie' do
      expect(trie).to be_empty
    end

    it 'returns false after inserting values' do
      trie.insert('ABCD', 'value')
      expect(trie).not_to be_empty
    end

    it 'returns true after clearing' do
      trie.insert('ABCD', 'value')
      trie.clear
      expect(trie).to be_empty
    end
  end
end
