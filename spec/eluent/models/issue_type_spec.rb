# frozen_string_literal: true

RSpec.describe Eluent::Models::IssueType do
  it_behaves_like 'a value object with extendable collection',
                  described_class,
                  described_class.defaults

  describe 'default issue types' do
    it 'includes feature' do
      expect(described_class[:feature]).to be_a(described_class)
    end

    it 'includes bug' do
      expect(described_class[:bug]).to be_a(described_class)
    end

    it 'includes task' do
      expect(described_class[:task]).to be_a(described_class)
    end

    it 'includes artifact' do
      expect(described_class[:artifact]).to be_a(described_class)
    end

    it 'includes epic' do
      expect(described_class[:epic]).to be_a(described_class)
    end

    it 'includes formula' do
      expect(described_class[:formula]).to be_a(described_class)
    end
  end

  describe '#initialize' do
    it 'sets the name' do
      issue_type = described_class.new(name: :custom)
      expect(issue_type.name).to eq(:custom)
    end

    it 'defaults abstract to false' do
      issue_type = described_class.new(name: :custom)
      expect(issue_type.abstract).to be false
    end

    it 'accepts abstract parameter' do
      issue_type = described_class.new(name: :custom, abstract: true)
      expect(issue_type.abstract).to be true
    end
  end

  describe '#abstract?' do
    it 'returns false for concrete types' do
      expect(described_class[:feature]).not_to be_abstract
      expect(described_class[:bug]).not_to be_abstract
      expect(described_class[:task]).not_to be_abstract
      expect(described_class[:artifact]).not_to be_abstract
    end

    it 'returns true for abstract types' do
      expect(described_class[:epic]).to be_abstract
      expect(described_class[:formula]).to be_abstract
    end
  end
end
