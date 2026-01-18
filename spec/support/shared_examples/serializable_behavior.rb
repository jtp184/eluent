# frozen_string_literal: true

RSpec.shared_examples 'a serializer' do
  describe '.serialize' do
    it 'returns a JSON string' do
      json = serializer.serialize(entity)
      expect(json).to be_a(String)
      expect { JSON.parse(json) }.not_to raise_error
    end

    it 'includes the type marker' do
      json = serializer.serialize(entity)
      parsed = JSON.parse(json, symbolize_names: true)
      expect(parsed[:_type]).to eq(expected_type)
    end
  end

  describe '.deserialize' do
    it 'returns nil for non-matching types' do
      data = { _type: 'other_type' }
      expect(serializer.deserialize(data)).to be_nil
    end

    it 'reconstructs an entity from a hash' do
      deserialized = serializer.deserialize(entity.to_h)
      expect(deserialized).to be_a(entity.class)
    end

    it 'handles string keys' do
      string_keyed = entity.to_h.transform_keys(&:to_s)
      deserialized = serializer.deserialize(string_keyed)
      expect(deserialized).to be_a(entity.class)
    end
  end

  describe 'round-trip serialization' do
    it 'preserves data through serialize/deserialize cycle' do
      json = serializer.serialize(entity)
      parsed = JSON.parse(json, symbolize_names: true)
      deserialized = serializer.deserialize(parsed)

      identity_attributes.each do |attr|
        expect(deserialized.public_send(attr)).to eq(entity.public_send(attr)),
                                                  "Expected #{attr} to be preserved"
      end
    end
  end

  describe '.type_match?' do
    it 'returns true for matching type' do
      expect(serializer.type_match?(entity.to_h)).to be true
    end

    it 'returns false for non-matching type' do
      expect(serializer.type_match?({ _type: 'other' })).to be false
    end

    it 'handles string keys' do
      string_keyed = { '_type' => expected_type }
      expect(serializer.type_match?(string_keyed)).to be true
    end
  end
end
