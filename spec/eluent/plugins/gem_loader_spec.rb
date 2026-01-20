# frozen_string_literal: true

RSpec.describe Eluent::Plugins::GemLoader do
  let(:loader) { described_class.new }

  describe 'GEM_PREFIX' do
    it 'is eluent-' do
      expect(described_class::GEM_PREFIX).to eq('eluent-')
    end
  end

  describe '#discover' do
    it 'finds gems with eluent- prefix' do
      mock_spec = instance_double(Gem::Specification, name: 'eluent-test-plugin')
      instance_double(Gem::Specification, name: 'rails')

      allow(Gem::Specification).to receive(:select).and_return([mock_spec])

      specs = loader.discover

      expect(specs).to include(mock_spec)
    end
  end

  describe '#load_gem_by_name' do
    it 'returns nil for unknown gem' do
      allow(Gem::Specification).to receive(:find_by_name)
        .with('unknown-gem')
        .and_raise(Gem::MissingSpecError.new('unknown-gem', []))

      result = loader.load_gem_by_name('unknown-gem')

      expect(result).to be_nil
    end
  end

  describe '#loaded' do
    it 'returns empty array initially' do
      expect(loader.loaded).to eq([])
    end

    it 'returns a copy of loaded gems' do
      loaded = loader.loaded
      loaded << 'fake'

      expect(loader.loaded).to eq([])
    end
  end

  describe described_class::LoadedGem do
    it 'stores gem info' do
      gem_info = described_class.new(
        name: 'eluent-test',
        version: '1.0.0',
        path: 'eluent/plugin'
      )

      expect(gem_info.name).to eq('eluent-test')
      expect(gem_info.version).to eq('1.0.0')
      expect(gem_info.path).to eq('eluent/plugin')
    end
  end

  describe described_class::LoadResult do
    it 'reports success when no errors' do
      result = described_class.new(loaded: [], errors: [])

      expect(result.success?).to be true
    end

    it 'reports failure when errors present' do
      error = Eluent::Plugins::PluginLoadError.new('test error')
      result = described_class.new(loaded: [], errors: [error])

      expect(result.success?).to be false
    end

    it 'contains loaded gems and errors' do
      loaded = [Eluent::Plugins::GemLoader::LoadedGem.new(name: 'test', version: '1.0', path: 'test')]
      error = Eluent::Plugins::PluginLoadError.new('error')
      result = described_class.new(loaded: loaded, errors: [error])

      expect(result.loaded.size).to eq(1)
      expect(result.errors.size).to eq(1)
    end
  end

  describe '#load_all!' do
    it 'returns a LoadResult' do
      allow(loader).to receive(:discover).and_return([])

      result = loader.load_all!

      expect(result).to be_a(described_class::LoadResult)
      expect(result.loaded).to eq([])
      expect(result.errors).to eq([])
    end
  end
end
