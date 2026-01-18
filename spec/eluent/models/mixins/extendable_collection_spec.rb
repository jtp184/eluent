# frozen_string_literal: true

RSpec.describe Eluent::Models::ExtendableCollection do
  # Create a test class that includes the module
  let(:test_class) do
    Class.new do
      include Eluent::Models::ExtendableCollection

      attr_reader :name, :value

      def initialize(name:, value: nil)
        @name = name
        @value = value
      end
    end
  end

  before do
    test_class.defaults = {
      alpha: { value: 1 },
      beta: { value: 2 },
      gamma: { value: 3 }
    }
    # Reset all to force re-initialization
    test_class.instance_variable_set(:@all, nil)
  end

  describe '.defaults' do
    it 'returns the configured defaults' do
      expect(test_class.defaults).to eq({
                                          alpha: { value: 1 },
                                          beta: { value: 2 },
                                          gamma: { value: 3 }
                                        })
    end

    it 'returns empty hash when not configured' do
      new_class = Class.new do
        include Eluent::Models::ExtendableCollection
      end
      expect(new_class.defaults).to eq({})
    end
  end

  describe '.all' do
    it 'creates instances from defaults' do
      all = test_class.all

      expect(all).to be_a(Hash)
      expect(all.keys).to contain_exactly(:alpha, :beta, :gamma)
    end

    it 'creates instances with correct attributes' do
      expect(test_class.all[:alpha].name).to eq(:alpha)
      expect(test_class.all[:alpha].value).to eq(1)
    end

    it 'memoizes the result' do
      first_call = test_class.all
      second_call = test_class.all

      expect(first_call).to be(second_call)
    end
  end

  describe '.[]' do
    it 'returns the instance by name' do
      instance = test_class[:alpha]

      expect(instance).to be_a(test_class)
      expect(instance.name).to eq(:alpha)
    end

    it 'raises KeyError for unknown names' do
      expect { test_class[:unknown] }.to raise_error(KeyError)
    end
  end

  describe '.[]=' do
    it 'allows adding new instances' do
      new_instance = test_class.new(name: :delta, value: 4)
      test_class[:delta] = new_instance

      expect(test_class[:delta]).to eq(new_instance)
    end

    it 'allows overwriting existing instances' do
      new_instance = test_class.new(name: :alpha, value: 100)
      test_class[:alpha] = new_instance

      expect(test_class[:alpha].value).to eq(100)
    end
  end
end
