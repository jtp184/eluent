# frozen_string_literal: true

RSpec.describe Eluent::Storage::Serializers::Base do
  # Create a test module that extends Base
  let(:test_serializer) do
    Module.new do
      extend Eluent::Storage::Serializers::Base

      class << self
        def type_name = 'test'
        def model_class = Struct.new(:id, :value, keyword_init: true)
        def extract_attributes(data) = data.slice(:id, :value)
      end
    end
  end

  let(:test_model) do
    Struct.new(:id, :value, keyword_init: true) do
      def to_h
        { _type: 'test', id: id, value: value }
      end
    end.new(id: '1', value: 'test')
  end

  describe '#serialize' do
    it 'converts model to JSON string' do
      json = test_serializer.serialize(test_model)
      expect(json).to be_a(String)
    end

    it 'produces valid JSON' do
      json = test_serializer.serialize(test_model)
      expect { JSON.parse(json) }.not_to raise_error
    end

    it 'includes the model hash data' do
      json = test_serializer.serialize(test_model)
      parsed = JSON.parse(json, symbolize_names: true)
      expect(parsed[:_type]).to eq('test')
      expect(parsed[:id]).to eq('1')
    end
  end

  describe '#type_match?' do
    it 'returns true for matching type with symbol keys' do
      expect(test_serializer.type_match?({ _type: 'test' })).to be true
    end

    it 'returns true for matching type with string keys' do
      expect(test_serializer.type_match?({ '_type' => 'test' })).to be true
    end

    it 'returns false for non-matching type' do
      expect(test_serializer.type_match?({ _type: 'other' })).to be false
    end

    it 'returns false for missing type' do
      expect(test_serializer.type_match?({})).to be false
    end
  end

  describe 'abstract methods' do
    let(:incomplete_serializer) do
      Module.new do
        extend Eluent::Storage::Serializers::Base
      end
    end

    it 'raises NotImplementedError for extract_attributes' do
      expect { incomplete_serializer.send(:extract_attributes, {}) }
        .to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for model_class' do
      expect { incomplete_serializer.send(:model_class) }
        .to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for type_name' do
      expect { incomplete_serializer.send(:type_name) }
        .to raise_error(NotImplementedError)
    end
  end
end
