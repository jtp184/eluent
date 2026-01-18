# frozen_string_literal: true

RSpec.describe Eluent::Models::DependencyType do
  it_behaves_like 'a value object with extendable collection',
                  described_class,
                  described_class.defaults

  describe 'default dependency types' do
    it 'includes blocks' do
      expect(described_class[:blocks]).to be_a(described_class)
    end

    it 'includes parent_child' do
      expect(described_class[:parent_child]).to be_a(described_class)
    end

    it 'includes conditional_blocks' do
      expect(described_class[:conditional_blocks]).to be_a(described_class)
    end

    it 'includes waits_for' do
      expect(described_class[:waits_for]).to be_a(described_class)
    end

    it 'includes related' do
      expect(described_class[:related]).to be_a(described_class)
    end

    it 'includes duplicates' do
      expect(described_class[:duplicates]).to be_a(described_class)
    end

    it 'includes discovered_from' do
      expect(described_class[:discovered_from]).to be_a(described_class)
    end

    it 'includes replies_to' do
      expect(described_class[:replies_to]).to be_a(described_class)
    end
  end

  describe '#initialize' do
    it 'sets the name' do
      dep_type = described_class.new(name: :custom)
      expect(dep_type.name).to eq(:custom)
    end

    it 'defaults blocking to false' do
      dep_type = described_class.new(name: :custom)
      expect(dep_type.blocking).to be false
    end

    it 'accepts blocking parameter' do
      dep_type = described_class.new(name: :custom, blocking: true)
      expect(dep_type.blocking).to be true
    end
  end

  describe '#blocking?' do
    context 'with blocking types' do
      it 'returns true for blocks' do
        expect(described_class[:blocks]).to be_blocking
      end

      it 'returns true for parent_child' do
        expect(described_class[:parent_child]).to be_blocking
      end

      it 'returns true for conditional_blocks' do
        expect(described_class[:conditional_blocks]).to be_blocking
      end

      it 'returns true for waits_for' do
        expect(described_class[:waits_for]).to be_blocking
      end
    end

    context 'with non-blocking types' do
      it 'returns false for related' do
        expect(described_class[:related]).not_to be_blocking
      end

      it 'returns false for duplicates' do
        expect(described_class[:duplicates]).not_to be_blocking
      end

      it 'returns false for discovered_from' do
        expect(described_class[:discovered_from]).not_to be_blocking
      end

      it 'returns false for replies_to' do
        expect(described_class[:replies_to]).not_to be_blocking
      end
    end
  end
end
