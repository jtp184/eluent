# frozen_string_literal: true

RSpec.shared_examples 'a value object with extendable collection' do |klass, defaults_hash|
  describe '.all' do
    it 'returns a hash of all instances' do
      expect(klass.all).to be_a(Hash)
      expect(klass.all).not_to be_empty
    end

    it 'contains the default instances' do
      defaults_hash.each_key do |name|
        expect(klass.all).to have_key(name)
      end
    end

    it 'returns instances of the correct class' do
      klass.all.each_value do |instance|
        expect(instance).to be_a(klass)
      end
    end
  end

  describe '.[]' do
    it 'retrieves an instance by name' do
      name = defaults_hash.keys.first
      expect(klass[name]).to be_a(klass)
      expect(klass[name].name).to eq(name)
    end

    it 'raises KeyError for unknown names' do
      expect { klass[:nonexistent_name] }.to raise_error(KeyError)
    end
  end

  describe '.[]=' do
    it 'allows adding new instances' do
      custom = klass.new(name: :custom_test)
      klass[:custom_test] = custom
      expect(klass[:custom_test]).to eq(custom)
    ensure
      # Clean up
      klass.all.delete(:custom_test)
    end
  end

  describe '#==' do
    it 'considers two instances with the same name equal' do
      name = defaults_hash.keys.first
      instance1 = klass[name]
      instance2 = klass.new(name: name)
      expect(instance1).to eq(instance2)
    end

    it 'considers instances with different names unequal' do
      names = defaults_hash.keys.take(2)
      next if names.length < 2

      expect(klass[names[0]]).not_to eq(klass[names[1]])
    end

    it 'is not equal to non-instances' do
      name = defaults_hash.keys.first
      expect(klass[name]).not_to eq(name)
      expect(klass[name]).not_to eq(name.to_s)
    end
  end

  describe '#eql?' do
    it 'behaves like ==' do
      name = defaults_hash.keys.first
      instance1 = klass[name]
      instance2 = klass.new(name: name)
      expect(instance1).to eql(instance2)
    end
  end

  describe '#hash' do
    it 'produces the same hash for equal instances' do
      name = defaults_hash.keys.first
      instance1 = klass[name]
      instance2 = klass.new(name: name)
      expect(instance1.hash).to eq(instance2.hash)
    end

    it 'can be used in hash keys' do
      name = defaults_hash.keys.first
      hash = { klass[name] => 'value' }
      expect(hash[klass.new(name: name)]).to eq('value')
    end
  end

  describe '#to_s' do
    it 'returns the name as a string' do
      name = defaults_hash.keys.first
      expect(klass[name].to_s).to eq(name.to_s)
    end
  end

  describe '#to_sym' do
    it 'returns the name as a symbol' do
      name = defaults_hash.keys.first
      expect(klass[name].to_sym).to eq(name)
    end
  end
end
