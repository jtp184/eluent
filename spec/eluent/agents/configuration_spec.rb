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
        agent_id: 'test-agent',
        skip_api_validation: true
      )

      hash = config.to_h

      expect(hash[:agent_id]).to eq('test-agent')
      expect(hash[:claude_configured]).to be true
      expect(hash[:openai_configured]).to be false
      expect(hash[:skip_api_validation]).to be true
      expect(hash).not_to have_key(:claude_api_key)
      expect(hash).not_to have_key(:openai_api_key)
    end
  end

  describe 'Claude Code configuration' do
    it 'has default claude_code_path' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new

      expect(config.claude_code_path).to eq('claude')
    end

    it 'accepts custom claude_code_path' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(claude_code_path: '/usr/local/bin/claude')

      expect(config.claude_code_path).to eq('/usr/local/bin/claude')
    end

    it 'has nil working_directory by default' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new

      expect(config.working_directory).to be_nil
    end

    it 'accepts custom working_directory' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(working_directory: '/my/project')

      expect(config.working_directory).to eq('/my/project')
    end

    it 'has preserve_sessions false by default' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new

      expect(config.preserve_sessions).to be false
    end

    it 'accepts preserve_sessions flag' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(preserve_sessions: true)

      expect(config.preserve_sessions).to be true
    end

    it 'has default context_directory' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new

      expect(config.context_directory).to eq('.eluent/agent-context')
    end

    it 'accepts custom context_directory' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(context_directory: '.custom/context')

      expect(config.context_directory).to eq('.custom/context')
    end

    it 'has skip_api_validation false by default' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new

      expect(config.skip_api_validation).to be false
    end

    it 'accepts skip_api_validation flag' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(skip_api_validation: true)

      expect(config.skip_api_validation).to be true
    end
  end

  describe '#validate! with skip_api_validation' do
    it 'skips API key check when skip_api_validation is true' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(skip_api_validation: true)

      expect { config.validate! }.not_to raise_error
    end

    it 'still validates other fields when skip_api_validation is true' do
      allow(ENV).to receive(:fetch).and_return(nil)
      config = described_class.new(skip_api_validation: true, execution_timeout: -1)

      expect { config.validate! }.to raise_error(
        Eluent::Agents::ConfigurationError,
        /Execution timeout must be positive/
      )
    end
  end
end
