# frozen_string_literal: true

RSpec.describe Eluent::Agents::ToolDefinitions do
  describe 'TOOLS' do
    it 'defines expected tools' do
      expect(described_class::TOOLS.keys).to include(
        :list_items, :show_item, :create_item, :update_item,
        :close_item, :list_ready_items, :add_dependency, :add_comment
      )
    end

    it 'has description for each tool' do
      described_class::TOOLS.each do |name, definition|
        expect(definition[:description]).to be_a(String), "Tool #{name} missing description"
      end
    end

    it 'has parameters schema for each tool' do
      described_class::TOOLS.each do |name, definition|
        expect(definition[:parameters]).to be_a(Hash), "Tool #{name} missing parameters"
        expect(definition[:parameters][:type]).to eq('object'), "Tool #{name} params not object type"
      end
    end
  end

  describe '.for_claude' do
    let(:tools) { described_class.for_claude }

    it 'returns array of tool definitions' do
      expect(tools).to be_an(Array)
      expect(tools.size).to eq(described_class::TOOLS.size)
    end

    it 'formats tools for Claude API' do
      tool = tools.find { |t| t[:name] == 'list_items' }

      expect(tool).to include(:name, :description, :input_schema)
      expect(tool[:input_schema]).to be_a(Hash)
    end

    it 'uses input_schema key for parameters' do
      tools.each do |tool|
        expect(tool).to have_key(:input_schema), "Tool #{tool[:name]} missing input_schema"
        expect(tool).not_to have_key(:parameters)
      end
    end
  end

  describe '.for_openai' do
    let(:tools) { described_class.for_openai }

    it 'returns array of tool definitions' do
      expect(tools).to be_an(Array)
      expect(tools.size).to eq(described_class::TOOLS.size)
    end

    it 'formats tools for OpenAI API' do
      tool = tools.find { |t| t[:function][:name] == 'list_items' }

      expect(tool[:type]).to eq('function')
      expect(tool[:function]).to include(:name, :description, :parameters)
    end

    it 'wraps each tool in function type' do
      tools.each do |tool|
        expect(tool[:type]).to eq('function')
        expect(tool[:function]).to be_a(Hash)
      end
    end
  end

  describe '.[]' do
    it 'returns tool definition by name' do
      tool = described_class[:list_items]

      expect(tool[:description]).to include('List work items')
    end

    it 'accepts string name' do
      tool = described_class['create_item']

      expect(tool[:description]).to include('Create')
    end

    it 'returns nil for unknown tool' do
      expect(described_class[:unknown]).to be_nil
    end
  end

  describe '.names' do
    it 'returns all tool names' do
      names = described_class.names

      expect(names).to include(:list_items, :show_item, :create_item)
    end
  end

  describe 'tool schema validations' do
    describe 'create_item' do
      let(:tool) { described_class[:create_item] }

      it 'requires title' do
        expect(tool[:parameters][:required]).to include('title')
      end

      it 'has optional fields' do
        properties = tool[:parameters][:properties]
        expect(properties).to have_key(:description)
        expect(properties).to have_key(:type)
        expect(properties).to have_key(:priority)
      end
    end

    describe 'close_item' do
      let(:tool) { described_class[:close_item] }

      it 'requires id' do
        expect(tool[:parameters][:required]).to include('id')
      end

      it 'has optional reason' do
        properties = tool[:parameters][:properties]
        expect(properties).to have_key(:reason)
      end
    end

    describe 'add_dependency' do
      let(:tool) { described_class[:add_dependency] }

      it 'requires source_id and target_id' do
        expect(tool[:parameters][:required]).to include('source_id', 'target_id')
      end

      it 'has optional dependency_type with enum' do
        properties = tool[:parameters][:properties]
        expect(properties[:dependency_type][:enum]).to include('blocks', 'needs_review')
      end
    end
  end
end
