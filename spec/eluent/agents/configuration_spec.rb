# frozen_string_literal: true

RSpec.describe Eluent::Agents::Configuration do
  describe '#initialize' do
    it 'uses default values' do
      allow(ENV).to receive(:fetch).with('ANTHROPIC_API_KEY', nil).and_return(nil)
      allow(ENV).to receive(:fetch).with('OPENAI_API_KEY', nil).and_return(nil)

      config = described_class.new

      expect(config.request_timeout).to eq(120)
      expect(config.execution_timeout).to eq(3600)
      expect(config.max_tool_calls).to eq(50)
      expect(config.max_retries).to eq(3)
    end

    it 'reads API keys from environment' do
      allow(ENV).to receive(:fetch).with('ANTHROPIC_API_KEY', nil).and_return('claude-key')
      allow(ENV).to receive(:fetch).with('OPENAI_API_KEY', nil).and_return('openai-key')

      config = described_class.new

      expect(config.claude_api_key).to eq('claude-key')
      expect(config.openai_api_key).to eq('openai-key')
    end

    it 'prefers explicit keys over environment' do
      allow(ENV).to receive(:fetch).with('ANTHROPIC_API_KEY', nil).and_return('env-key')
      allow(ENV).to receive(:fetch).with('OPENAI_API_KEY', nil).and_return(nil)

      config = described_class.new(claude_api_key: 'explicit-key')

      expect(config.claude_api_key).to eq('explicit-key')
    end

    it 'generates agent_id' do
      allow(ENV).to receive(:fetch).and_return(nil)

      config = described_class.new

      expect(config.agent_id).to match(/^agent-\w+-\d+$/)
    end

    it 'accepts custom agent_id' do
      allow(ENV).to receive(:fetch).and_return(nil)

      config = described_class.new(agent_id: 'custom-agent')

      expect(config.agent_id).to eq('custom-agent')
    end
  end

  describe '#claude_configured?' do
    it 'returns true when claude key is set' do
      config = described_class.new(claude_api_key: 'sk-ant-xxx')
      expect(config.claude_configured?).to be true
    end

    it 'returns false when claude key is nil' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new
      expect(config.claude_configured?).to be false
    end

    it 'returns false when claude key is empty' do
      config = described_class.new(claude_api_key: '')
      expect(config.claude_configured?).to be false
    end
  end

  describe '#openai_configured?' do
    it 'returns true when openai key is set' do
      config = described_class.new(openai_api_key: 'sk-xxx')
      expect(config.openai_configured?).to be true
    end

    it 'returns false when openai key is nil' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new
      expect(config.openai_configured?).to be false
    end
  end

  describe '#any_provider_configured?' do
    it 'returns true when claude is configured' do
      config = described_class.new(claude_api_key: 'key')
      expect(config.any_provider_configured?).to be true
    end

    it 'returns true when openai is configured' do
      config = described_class.new(openai_api_key: 'key')
      expect(config.any_provider_configured?).to be true
    end

    it 'returns false when neither is configured' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new
      expect(config.any_provider_configured?).to be false
    end
  end

  describe '#validate!' do
    it 'raises when no API provider configured' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new

      expect { config.validate! }.to raise_error(
        Eluent::Agents::ConfigurationError,
        /No API provider configured/
      )
    end

    it 'raises when request_timeout is non-positive' do
      config = described_class.new(claude_api_key: 'key', request_timeout: 0)

      expect { config.validate! }.to raise_error(
        Eluent::Agents::ConfigurationError,
        /Request timeout must be positive/
      )
    end

    it 'raises when execution_timeout is non-positive' do
      config = described_class.new(claude_api_key: 'key', execution_timeout: -1)

      expect { config.validate! }.to raise_error(
        Eluent::Agents::ConfigurationError,
        /Execution timeout must be positive/
      )
    end

    it 'raises when max_tool_calls is non-positive' do
      config = described_class.new(claude_api_key: 'key', max_tool_calls: 0)

      expect { config.validate! }.to raise_error(
        Eluent::Agents::ConfigurationError,
        /Max tool calls must be positive/
      )
    end

    it 'returns true when valid' do
      config = described_class.new(claude_api_key: 'key')
      expect(config.validate!).to be true
    end
  end

  describe '#to_h' do
    it 'returns configuration hash without secrets' do
      allow(ENV).to receive(:fetch).and_return(nil)

      config = described_class.new(
        claude_api_key: 'secret',
        openai_api_key: nil,
        agent_id: 'test-agent'
      )

      hash = config.to_h

      expect(hash[:agent_id]).to eq('test-agent')
      expect(hash[:claude_configured]).to be true
      expect(hash[:openai_configured]).to be false
      expect(hash).not_to have_key(:claude_api_key)
      expect(hash).not_to have_key(:openai_api_key)
    end
  end
end
