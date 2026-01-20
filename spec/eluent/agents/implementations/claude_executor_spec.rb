# frozen_string_literal: true

require 'httpx'

# rubocop:disable RSpec/VerifiedDoubles -- HTTPX doesn't expose internal classes publicly
RSpec.describe Eluent::Agents::Implementations::ClaudeExecutor do
  let(:repository) { instance_double(Eluent::Storage::JsonlRepository) }
  let(:configuration) do
    Eluent::Agents::Configuration.new(
      claude_api_key: 'sk-ant-test-key',
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
        # Ensure claude_api_key is nil by passing nil explicitly
        Eluent::Agents::Configuration.new(openai_api_key: 'key', claude_api_key: nil, agent_id: 'test')
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
          body: { content: [{ type: 'text', text: 'Task completed' }] }
        )
        allow(repository).to receive(:find_atom).with('test-123').and_return(atom)
      end

      it 'returns success result' do
        result = executor.execute(atom)

        expect(result.success).to be true
        expect(result.atom).to eq(atom)
      end
    end

    context 'with tool use response' do
      before do
        tool_response = { content: [{ type: 'tool_use', id: 'tool-1', name: 'list_items', input: {} }] }
        text_response = { content: [{ type: 'text', text: 'Done' }] }
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
            content: [
              { type: 'tool_use', id: 'tool-1', name: 'close_item', input: { id: 'test-123', reason: 'Completed' } }
            ]
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

    context 'with nil response body' do
      before do
        response = instance_double(HTTPX::Response)
        allow(response).to receive_messages(status: 200, body: nil)

        httpx_chain = double('HTTPX chain')
        allow(HTTPX).to receive(:with).and_return(httpx_chain)
        allow(httpx_chain).to receive_messages(with: httpx_chain, post: response)

        allow(repository).to receive(:find_atom).with('test-123').and_return(atom)
      end

      it 'handles nil body gracefully' do
        result = executor.execute(atom)

        # Should succeed without throwing an error
        expect(result.success).to be true
      end
    end

    context 'when atom is deleted during execution' do
      before do
        stub_httpx_request(
          status: 200,
          body: { content: [{ type: 'text', text: 'Done' }] }
        )
        # Return nil on second find_atom call (after execution)
        allow(repository).to receive(:find_atom).with('test-123').and_return(nil)
      end

      it 'returns failure result' do
        result = executor.execute(atom)

        expect(result.success).to be false
        expect(result.error).to include('deleted during execution')
      end
    end
  end

  describe 'constants' do
    it 'uses Claude API URL' do
      expect(described_class::API_URL).to eq('https://api.anthropic.com/v1/messages')
    end

    it 'specifies model' do
      expect(described_class::MODEL).to be_a(String)
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
