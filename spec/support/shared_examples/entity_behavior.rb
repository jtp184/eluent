# frozen_string_literal: true

RSpec.shared_examples 'an entity with identity' do
  describe '#==' do
    it 'considers entities with the same identity equal' do
      expect(entity).to eq(same_identity_entity)
    end

    it 'considers entities with different identities unequal' do
      expect(entity).not_to eq(different_identity_entity)
    end

    it 'is not equal to nil' do
      expect(entity).not_to eq(nil)
    end

    it 'is not equal to other types' do
      expect(entity).not_to eq('string')
      expect(entity).not_to eq(123)
    end
  end

  describe '#eql?' do
    it 'behaves like ==' do
      expect(entity).to eql(same_identity_entity)
      expect(entity).not_to eql(different_identity_entity)
    end
  end

  describe '#hash' do
    it 'produces the same hash for equal entities' do
      expect(entity.hash).to eq(same_identity_entity.hash)
    end

    it 'can be used as hash keys' do
      hash = { entity => 'value' }
      expect(hash[same_identity_entity]).to eq('value')
    end

    it 'can be used in sets' do
      set = Set.new([entity])
      expect(set).to include(same_identity_entity)
      expect(set).not_to include(different_identity_entity)
    end
  end
end

RSpec.shared_examples 'a serializable entity' do
  describe '#to_h' do
    subject(:hash) { entity.to_h }

    it 'returns a Hash' do
      expect(hash).to be_a(Hash)
    end

    it 'includes the _type key' do
      expect(hash).to have_key(:_type)
    end

    it 'contains the expected type value' do
      expect(hash[:_type]).to eq(expected_type)
    end

    it 'contains all expected keys' do
      expected_keys.each do |key|
        expect(hash).to have_key(key), "Expected hash to have key #{key.inspect}"
      end
    end

    it 'produces JSON-serializable output' do
      expect { JSON.generate(hash) }.not_to raise_error
    end

    it 'formats timestamps as ISO8601' do
      timestamp_keys.each do |key|
        next if hash[key].nil?

        expect(hash[key]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
      end
    end
  end
end
