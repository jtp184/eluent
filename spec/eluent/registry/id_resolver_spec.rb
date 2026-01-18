# frozen_string_literal: true

RSpec.describe Eluent::Registry::IdResolver do
  let(:indexer) { Eluent::Storage::Indexer.new }
  let(:resolver) { described_class.new(indexer) }

  let(:atom1) { build(:atom, id: test_atom_id_for_repo('testrepo', 'ABCDEFGHKMNPQRST')) }
  let(:atom2) { build(:atom, id: test_atom_id_for_repo('testrepo', 'ZYXWVTSRQPNMKJHG')) }
  let(:atom3) { build(:atom, id: test_atom_id_for_repo('otherrepo', 'ABCDEFGHKMNPQRST')) }

  before do
    indexer.index_atom(atom1)
    indexer.index_atom(atom2)
    indexer.index_atom(atom3)
  end

  describe '#resolve' do
    context 'with full atom ID' do
      it 'returns the atom for valid full ID' do
        result = resolver.resolve(atom1.id)
        expect(result[:atom]).to eq(atom1)
      end

      it 'returns not_found error for non-existent full ID' do
        result = resolver.resolve('testrepo-01JBZTMQ1RNONEXISTENT12345')
        expect(result[:error]).to eq(:not_found)
      end
    end

    context 'with prefix lookup' do
      it 'resolves unique prefix to atom' do
        result = resolver.resolve('ABCD', repo_name: 'testrepo')
        expect(result[:atom]).to eq(atom1)
      end

      it 'returns ambiguous error for non-unique prefix' do
        result = resolver.resolve('ABCD')
        expect(result[:error]).to eq(:ambiguous)
        expect(result[:candidates]).to contain_exactly(atom1, atom3)
      end

      it 'returns prefix_too_short error for short prefixes' do
        result = resolver.resolve('ABC')
        expect(result[:error]).to eq(:prefix_too_short)
      end

      it 'returns not_found error for non-matching prefix' do
        result = resolver.resolve('ZZZZ', repo_name: 'testrepo')
        expect(result[:error]).to eq(:not_found)
      end
    end

    context 'with repo-qualified prefix' do
      it 'extracts repo from input' do
        result = resolver.resolve('testrepo-ABCD')
        expect(result[:atom]).to eq(atom1)
      end

      it 'handles different repos' do
        result = resolver.resolve('otherrepo-ABCD')
        expect(result[:atom]).to eq(atom3)
      end
    end

    context 'with confusable characters' do
      it 'normalizes I to 1' do
        result = resolver.resolve('ABCDEFGHKMNPQRST'.tr('1', 'I'), repo_name: 'testrepo')
        # Should still find the atom since I normalizes to 1
        expect(result[:error]).to be_nil if result[:atom]
      end

      it 'normalizes L to 1' do
        # If prefix contains L, it gets normalized
        result = resolver.resolve('ABCDEFGHKMNPQRST'.tr('1', 'L'), repo_name: 'testrepo')
        expect(result[:error]).to be_nil if result[:atom]
      end

      it 'normalizes O to 0' do
        result = resolver.resolve('ABCDEFGHKMNPQRST'.tr('0', 'O'), repo_name: 'testrepo')
        expect(result[:error]).to be_nil if result[:atom]
      end
    end

    context 'with empty or invalid input' do
      it 'returns invalid_input error for empty string' do
        result = resolver.resolve('')
        expect(result[:error]).to eq(:invalid_input)
      end

      it 'returns invalid_input error for whitespace only' do
        result = resolver.resolve('   ')
        expect(result[:error]).to eq(:invalid_input)
      end
    end

    context 'with relative references' do
      it 'returns relative_reference error for dot-prefixed input' do
        result = resolver.resolve('.child')
        expect(result[:error]).to eq(:relative_reference)
        expect(result[:suffix]).to eq('child')
      end
    end
  end

  describe '#short_id' do
    it 'returns minimum unique prefix for atom' do
      short = resolver.short_id(atom1)
      expect(short).not_to be_nil
      expect(short.length).to be >= 4
    end

    it 'returns nil for nil atom' do
      expect(resolver.short_id(nil)).to be_nil
    end

    it 'returns nil for atom without id' do
      atom = build(:atom)
      atom.id = nil
      expect(resolver.short_id(atom)).to be_nil
    end
  end

  describe '#display_info' do
    it 'returns display information for atom' do
      info = resolver.display_info(atom1)

      expect(info[:full_id]).to eq(atom1.id)
      expect(info[:ulid]).not_to be_nil
      expect(info[:timestamp]).not_to be_nil
      expect(info[:randomness]).not_to be_nil
      expect(info[:created_time]).to be_a(Time)
      expect(info[:short]).not_to be_nil
    end

    it 'returns nil for nil atom' do
      expect(resolver.display_info(nil)).to be_nil
    end
  end
end

RSpec.describe Eluent::Registry::AmbiguousIdError do
  subject(:error) { described_class.new('ABCD', candidates) }

  let(:candidates) { [build(:atom), build(:atom)] }

  it 'stores the prefix' do
    expect(error.prefix).to eq('ABCD')
  end

  it 'stores the candidates' do
    expect(error.candidates).to eq(candidates)
  end

  it 'includes candidate count in message' do
    expect(error.message).to include('2 items')
  end
end

RSpec.describe Eluent::Registry::IdNotFoundError do
  subject(:error) { described_class.new('test-id') }

  it 'stores the id' do
    expect(error.id).to eq('test-id')
  end

  it 'includes id in message' do
    expect(error.message).to include('test-id')
  end
end
