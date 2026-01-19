# frozen_string_literal: true

RSpec.describe Eluent::Sync::SyncState, :filesystem do
  let(:root_path) { '/project' }
  let(:paths) { Eluent::Storage::Paths.new(root_path) }
  let(:sync_state) { described_class.new(paths: paths) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    setup_eluent_directory(root_path)
  end

  after { FakeFS.deactivate! }

  describe '#initialize' do
    it 'sets paths' do
      expect(sync_state.send(:paths)).to eq(paths)
    end

    it 'initializes with nil values' do
      expect(sync_state.last_sync_at).to be_nil
      expect(sync_state.base_commit).to be_nil
      expect(sync_state.local_head).to be_nil
      expect(sync_state.remote_head).to be_nil
    end
  end

  describe '#exists?' do
    it 'returns false when sync state file does not exist' do
      expect(sync_state.exists?).to be false
    end

    it 'returns true when sync state file exists' do
      File.write(paths.sync_state_file, '{}')
      expect(sync_state.exists?).to be true
    end
  end

  describe '#load' do
    context 'when file does not exist' do
      it 'returns self with nil values' do
        result = sync_state.load
        expect(result).to eq(sync_state)
        expect(sync_state.last_sync_at).to be_nil
      end
    end

    context 'when file exists' do
      let(:sync_time) { Time.utc(2025, 1, 15, 10, 30, 0) }

      before do
        File.write(paths.sync_state_file, JSON.generate(
                                            last_sync_at: sync_time.iso8601,
                                            base_commit: 'abc123',
                                            local_head: 'def456',
                                            remote_head: 'ghi789'
                                          ))
      end

      it 'loads the sync state' do
        sync_state.load
        expect(sync_state.last_sync_at).to eq(sync_time)
        expect(sync_state.base_commit).to eq('abc123')
        expect(sync_state.local_head).to eq('def456')
        expect(sync_state.remote_head).to eq('ghi789')
      end
    end
  end

  describe '#save' do
    let(:sync_time) { Time.utc(2025, 1, 15, 10, 30, 0) }

    before do
      sync_state.update(
        last_sync_at: sync_time,
        base_commit: 'abc123',
        local_head: 'def456',
        remote_head: 'ghi789'
      )
    end

    it 'writes the sync state to file' do
      sync_state.save
      expect(File.exist?(paths.sync_state_file)).to be true

      content = JSON.parse(File.read(paths.sync_state_file), symbolize_names: true)
      expect(content[:last_sync_at]).to eq(sync_time.iso8601)
      expect(content[:base_commit]).to eq('abc123')
    end

    it 'returns self' do
      expect(sync_state.save).to eq(sync_state)
    end
  end

  describe '#update' do
    let(:sync_time) { Time.utc(2025, 1, 15, 10, 30, 0) }

    it 'updates all fields' do
      sync_state.update(
        last_sync_at: sync_time,
        base_commit: 'abc123',
        local_head: 'def456',
        remote_head: 'ghi789'
      )

      expect(sync_state.last_sync_at).to eq(sync_time)
      expect(sync_state.base_commit).to eq('abc123')
      expect(sync_state.local_head).to eq('def456')
      expect(sync_state.remote_head).to eq('ghi789')
    end

    it 'returns self' do
      result = sync_state.update(
        last_sync_at: sync_time,
        base_commit: 'abc',
        local_head: 'def',
        remote_head: 'ghi'
      )
      expect(result).to eq(sync_state)
    end
  end

  describe '#reset!' do
    before do
      sync_state.update(
        last_sync_at: Time.now.utc,
        base_commit: 'abc123',
        local_head: 'def456',
        remote_head: 'ghi789'
      ).save
    end

    it 'clears all fields' do
      sync_state.reset!
      expect(sync_state.last_sync_at).to be_nil
      expect(sync_state.base_commit).to be_nil
      expect(sync_state.local_head).to be_nil
      expect(sync_state.remote_head).to be_nil
    end

    it 'deletes the file' do
      expect(File.exist?(paths.sync_state_file)).to be true
      sync_state.reset!
      expect(File.exist?(paths.sync_state_file)).to be false
    end

    it 'returns self' do
      expect(sync_state.reset!).to eq(sync_state)
    end
  end

  describe '#to_h' do
    let(:sync_time) { Time.utc(2025, 1, 15, 10, 30, 0) }

    before do
      sync_state.update(
        last_sync_at: sync_time,
        base_commit: 'abc123',
        local_head: 'def456',
        remote_head: 'ghi789'
      )
    end

    it 'returns a hash representation' do
      hash = sync_state.to_h
      expect(hash[:last_sync_at]).to eq(sync_time.iso8601)
      expect(hash[:base_commit]).to eq('abc123')
      expect(hash[:local_head]).to eq('def456')
      expect(hash[:remote_head]).to eq('ghi789')
    end
  end
end
