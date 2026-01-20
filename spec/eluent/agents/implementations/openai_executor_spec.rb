# frozen_string_literal: true

require 'httpx'

# rubocop:disable RSpec/VerifiedDoubles -- HTTPX doesn't expose internal classes publicly
RSpec.describe Eluent::Agents::Implementations::OpenAIExecutor do
  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      openai_api_key: 'sk-test-key',
      agent_id: 'test-agent'
    )
  end
  let(:executor) { described_class.new(repository: repository, configuration: configuration) }
  let(:atom) { Eluent::Models::Atom.new(id: 'test-123', title: 'Test Task') }

  def stub_httpx_request(status:, body:, headers: {})
    response = instance_double(HTTPX::Response)
    allow(response).to receive_messages(status: status, body: double(to_s: JSON.generate(body)), headers: headers)

    httpx_chain = double('HTTPX chain')
    allow(HTTPX).to receive(:with).and_return(httpx_chain)
    allow(httpx_chain).to receive_messages(with: httpx_chain, post: response)
    httpx_chain
  end

  describe '#execute' do
    context 'when not configured' do
      let(:configuration) do
        # Stub ENV to ensure no real API key interferes
        allow(ENV).to receive(:fetch).with('ANTHROPIC_API_KEY', nil).and_return(nil)
        allow(ENV).to receive(:fetch).with('OPENAI_API_KEY', nil).and_return(nil)
        Eluent::Agents::Configuration.new(claude_api_key: 'key', agent_id: 'test')
      end

      it 'returns failure result' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('not configured')
      end
    end

    context 'with successful text response' do
      before do
        stub_httpx_request(
          status: 200,
          body: { choices: [{ message: { role: 'assistant', content: 'Task completed' } }] }
        )
        allow(repository).to receive(:find_atom).with('test-123').and_return(atom)
      end

      it 'returns success result' do
        result = executor.execute(atom)

        expect(result.success).to be true
        expect(result.atom).to eq(atom)
      end
    end

    context 'with tool call response' do
      before do
        tool_response = {
          choices: [{
            message: {
              role: 'assistant',
              content: nil,
              tool_calls: [{ id: 'call-1', type: 'function', function: { name: 'list_items', arguments: '{}' } }]
            }
          }]
        }
        text_response = { choices: [{ message: { role: 'assistant', content: 'Done' } }] }
        responses = [tool_response, text_response]

        response_index = 0
        httpx_chain = double('HTTPX chain')
        allow(HTTPX).to receive(:with).and_return(httpx_chain)
        allow(httpx_chain).to receive(:with).and_return(httpx_chain)
        allow(httpx_chain).to receive(:post) do
          resp = instance_double(HTTPX::Response)
          allow(resp).to receive_messages(status: 200, body: double(to_s: JSON.generate(responses[response_index])))
          response_index += 1
          resp
        end

        allow(repository).to receive(:list_atoms).and_return([])
        allow(repository).to receive(:find_atom).with('test-123').and_return(atom)
      end

      it 'executes tool and continues' do
        result = executor.execute(atom)

        expect(result.success).to be true
      end
    end

    context 'with authentication error' do
      before do
        stub_httpx_request(
          status: 401,
          body: { error: { message: 'Invalid API key' } }
        )
      end

      it 'returns failure with auth error' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Invalid API key')
      end
    end

    context 'with rate limit error' do
      before do
        stub_httpx_request(
          status: 429,
          body: { error: { message: 'Rate limit exceeded' } },
          headers: { 'retry-after' => '60' }
        )
      end

      it 'returns failure with rate limit error' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('Rate limit')
      end
    end

    context 'when close_item tool is called' do
      let(:closed_atom) do
        Eluent::Models::Atom.new(
          id: 'test-123',
          title: 'Test Task',
          status: Eluent::Models::Status[:closed],
          close_reason: 'Completed'
        )
      end

      before do
        stub_httpx_request(
          status: 200,
          body: {
            choices: [{
              message: {
                role: 'assistant',
                content: nil,
                tool_calls: [{
                  id: 'call-1',
                  type: 'function',
                  function: { name: 'close_item', arguments: '{"id":"test-123","reason":"Completed"}' }
                }]
              }
            }]
          }
        )
        allow(repository).to receive(:find_atom).with('test-123').and_return(atom, closed_atom)
        allow(repository).to receive(:update_atom).and_return(closed_atom)
      end

      it 'returns success with close reason' do
        result = executor.execute(atom)

        expect(result.success).to be true
        expect(result.close_reason).to eq('Completed')
      end
    end
  end

  describe 'constants' do
    it 'uses OpenAI API URL' do
      expect(described_class::API_URL).to eq('https://api.openai.com/v1/chat/completions')
    end

    it 'specifies model' do
      expect(described_class::MODEL).to eq('gpt-4o')
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
