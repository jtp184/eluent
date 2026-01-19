# frozen_string_literal: true

RSpec.describe Eluent::Daemon::CommandRouter do
  let(:router) { described_class.new }

  describe 'COMMANDS' do
    it 'includes expected commands' do
      expect(described_class::COMMANDS).to include('ping', 'list', 'show', 'create', 'update', 'close', 'sync')
    end
  end

  describe '#route' do
    describe 'ping command' do
      let(:request) { { id: 'req-123', cmd: 'ping', args: {} } }

      it 'returns success with pong' do
        response = router.route(request)
        expect(response[:status]).to eq('ok')
        expect(response[:id]).to eq('req-123')
        expect(response[:data][:pong]).to be true
      end

      it 'includes timestamp' do
        response = router.route(request)
        expect(response[:data][:time]).to match(/\d{4}-\d{2}-\d{2}T/)
      end
    end

    describe 'unknown command' do
      let(:request) { { id: 'req-123', cmd: 'unknown', args: {} } }

      it 'returns error' do
        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('UNKNOWN_COMMAND')
      end
    end

    describe 'command without repo_path' do
      let(:request) { { id: 'req-123', cmd: 'list', args: {} } }

      it 'returns repo not found error' do
        response = router.route(request)
        expect(response[:status]).to eq('error')
        expect(response[:error][:code]).to eq('REPO_NOT_FOUND')
      end
    end
  end

  describe 'repository caching' do
    def setup_fake_repo(path)
      FileUtils.mkdir_p("#{path}/.eluent")
      File.write("#{path}/.eluent/data.jsonl", "{\"_type\":\"header\",\"repo_name\":\"test\"}\n")
      File.write("#{path}/.eluent/config.yaml", "repo_name: test\n")
      FileUtils.mkdir_p("#{path}/.git")
    end

    it 'caches repositories by path', :filesystem do
      FakeFS.activate!
      FakeFS::FileSystem.clear

      begin
        setup_fake_repo('/project')

        router.route({ id: 'req-1', cmd: 'list', args: { repo_path: '/project' } })
        router.route({ id: 'req-2', cmd: 'list', args: { repo_path: '/project' } })

        expect(router.send(:repo_cache).keys).to eq(['/project'])
      ensure
        FakeFS.deactivate!
      end
    end
  end
end
