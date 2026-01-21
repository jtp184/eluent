# frozen_string_literal: true

# ==============================================================================
# LedgerSyncState Specs
# ==============================================================================
#
# LedgerSyncState persists ledger sync metadata (timestamps, HEAD SHA, offline
# claims) to disk for recovery and offline reconciliation.
#
# Test categories:
# 1. Initialization and defaults
# 2. Loading and saving state
# 3. Pull/push tracking
# 4. Offline claim management
# 5. Schema migration
# 6. Error handling and corruption recovery
# 7. File locking and atomicity

require 'json'

RSpec.describe Eluent::Sync::LedgerSyncState, :filesystem do
  let(:repo_name) { 'test-repo' }
  let(:frozen_time) { Time.utc(2026, 1, 20, 12, 0, 0) }
  let(:clock) { class_double(Time, now: frozen_time) }
  let(:global_paths) do
    instance_double(
      Eluent::Storage::GlobalPaths,
      ledger_sync_state_file: '/home/user/.eluent/test-repo/.ledger-sync-state',
      ledger_lock_file: '/home/user/.eluent/test-repo/.ledger.lock'
    )
  end

  let(:state) { described_class.new(global_paths: global_paths, clock: clock) }

  before do
    FakeFS.activate!
    FakeFS::FileSystem.clear
    FileUtils.mkdir_p('/home/user/.eluent/test-repo')
  end

  after { FakeFS.deactivate! }

  # ===========================================================================
  # Constants
  # ===========================================================================

  describe 'constants' do
    it 'defines VERSION for schema versioning' do
      expect(described_class::VERSION).to eq(1)
    end

    it 'defines MAX_OFFLINE_CLAIMS to prevent unbounded growth' do
      expect(described_class::MAX_OFFLINE_CLAIMS).to eq(1000)
    end

    it 'defines MAX_SHA_LENGTH to limit SHA storage' do
      expect(described_class::MAX_SHA_LENGTH).to eq(64)
    end

    it 'defines MAX_ATOM_ID_LENGTH to limit atom ID storage' do
      expect(described_class::MAX_ATOM_ID_LENGTH).to eq(256)
    end

    it 'defines MAX_AGENT_ID_LENGTH to limit agent ID storage' do
      expect(described_class::MAX_AGENT_ID_LENGTH).to eq(256)
    end
  end

  # ===========================================================================
  # Initialization
  # ===========================================================================

  describe '#initialize' do
    it 'starts with nil timestamps' do
      expect(state.last_pull_at).to be_nil
      expect(state.last_push_at).to be_nil
    end

    it 'starts with nil ledger_head' do
      expect(state.ledger_head).to be_nil
    end

    it 'starts with valid as false' do
      expect(state.valid?).to be false
    end

    it 'starts with empty offline_claims' do
      expect(state.offline_claims).to eq([])
    end

    it 'starts with current schema_version' do
      expect(state.schema_version).to eq(described_class::VERSION)
    end
  end

  # ===========================================================================
  # Persistence: exists?, load, save
  # ===========================================================================

  describe '#exists?' do
    it 'returns false when state file does not exist' do
      expect(state.exists?).to be false
    end

    it 'returns true when state file exists' do
      File.write(global_paths.ledger_sync_state_file, '{}')
      expect(state.exists?).to be true
    end
  end

  describe '#load' do
    context 'when state file does not exist' do
      it 'returns self with default values' do
        result = state.load

        expect(result).to eq(state)
        expect(state.last_pull_at).to be_nil
        expect(state.offline_claims).to eq([])
      end
    end

    context 'when state file exists with valid data' do
      let(:pull_time) { Time.utc(2026, 1, 19, 10, 0, 0) }
      let(:push_time) { Time.utc(2026, 1, 19, 11, 0, 0) }

      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 1,
                                                          last_pull_at: pull_time.iso8601,
                                                          last_push_at: push_time.iso8601,
                                                          ledger_head: 'abc123',
                                                          valid: true,
                                                          offline_claims: [
                                                            {
                                                              atom_id: 'TSV4', agent_id: 'agent-1',
                                                              claimed_at: pull_time.iso8601
                                                            }
                                                          ]
                                                        ))
      end

      it 'loads all fields' do
        state.load

        expect(state.last_pull_at).to eq(pull_time)
        expect(state.last_push_at).to eq(push_time)
        expect(state.ledger_head).to eq('abc123')
        expect(state.valid?).to be true
        expect(state.offline_claims.size).to eq(1)
        expect(state.offline_claims.first.atom_id).to eq('TSV4')
      end

      it 'returns self for method chaining' do
        expect(state.load).to eq(state)
      end
    end

    context 'when state file is corrupted (invalid JSON)' do
      before do
        File.write(global_paths.ledger_sync_state_file, 'not valid json {{{')
      end

      it 'resets to default state and warns' do
        allow(state).to receive(:warn)

        state.load

        expect(state).to have_received(:warn).with(/corrupted ledger sync state/)
        expect(state.last_pull_at).to be_nil
        expect(state.offline_claims).to eq([])
      end

      it 'deletes the corrupted file' do
        allow(state).to receive(:warn)
        state.load

        expect(File.exist?(global_paths.ledger_sync_state_file)).to be false
      end
    end

    context 'when state file is truncated (incomplete write)' do
      before do
        File.write(global_paths.ledger_sync_state_file, '{"schema_version": 1, "last_pull')
      end

      it 'handles truncated file as corruption' do
        allow(state).to receive(:warn)

        state.load

        expect(state).to have_received(:warn).with(/corrupted/)
        expect(state.last_pull_at).to be_nil
      end
    end

    context 'when schema version is older than current' do
      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 0,
                                                          last_pull_at: frozen_time.iso8601,
                                                          ledger_head: 'abc123'
                                                        ))
      end

      it 'loads data and upgrades schema version' do
        state.load

        expect(state.schema_version).to eq(described_class::VERSION)
        expect(state.ledger_head).to eq('abc123')
      end
    end

    context 'when schema version is missing (pre-versioning file)' do
      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          last_pull_at: frozen_time.iso8601,
                                                          ledger_head: 'abc123'
                                                        ))
      end

      it 'treats missing version as version 1' do
        state.load

        expect(state.schema_version).to eq(1)
        expect(state.ledger_head).to eq('abc123')
      end
    end

    context 'when schema version is newer than supported' do
      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 999,
                                                          last_pull_at: frozen_time.iso8601
                                                        ))
      end

      it 'raises LedgerSyncStateError with upgrade suggestion' do
        expect { state.load }
          .to raise_error(Eluent::Sync::LedgerSyncStateError, /newer than supported.*upgrade eluent/i)
      end
    end

    context 'when valid is missing from file' do
      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 1,
                                                          last_pull_at: frozen_time.iso8601
                                                        ))
      end

      it 'defaults valid to false' do
        state.load

        expect(state.valid?).to be false
      end
    end

    context 'when offline_claims is missing from file' do
      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 1,
                                                          last_pull_at: frozen_time.iso8601
                                                        ))
      end

      it 'defaults offline_claims to empty array' do
        state.load

        expect(state.offline_claims).to eq([])
      end
    end

    context 'when timestamps contain invalid values' do
      before do
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 1,
                                                          last_pull_at: 'not-a-valid-timestamp',
                                                          last_push_at: '',
                                                          ledger_head: 'abc123'
                                                        ))
      end

      it 'treats invalid time strings as nil' do
        state.load

        expect(state.last_pull_at).to be_nil
        expect(state.last_push_at).to be_nil
        expect(state.ledger_head).to eq('abc123')
      end
    end

    context 'when offline_claims contain invalid timestamps' do
      before do
        bad_claim = { atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: 'garbage' }
        File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                          schema_version: 1,
                                                          offline_claims: [bad_claim]
                                                        ))
      end

      it 'loads claim with nil claimed_at for invalid timestamp' do
        state.load

        expect(state.offline_claims.size).to eq(1)
        expect(state.offline_claims.first.atom_id).to eq('TSV4')
        expect(state.offline_claims.first.claimed_at).to be_nil
      end
    end

    context 'when file contains binary/non-UTF8 data' do
      before do
        File.binwrite(global_paths.ledger_sync_state_file, "{\x80\x81\x82}")
      end

      it 'resets state and warns about corruption' do
        warnings = []
        allow(state).to receive(:warn) { |msg| warnings << msg }

        state.load

        expect(warnings.first).to include('corrupted ledger sync state')
        expect(state.last_pull_at).to be_nil
      end
    end

    context 'when file is deleted after exist check (race condition)' do
      it 'resets state gracefully on ENOENT' do
        allow(File).to receive(:exist?).and_return(true)
        allow(state).to receive(:warn)

        state.load

        expect(state).to have_received(:warn).with(/corrupted/)
        expect(state.last_pull_at).to be_nil
      end
    end
  end

  describe '#save' do
    before do
      state.update_pull(head_sha: 'abc123')
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: frozen_time)
    end

    it 'writes state to file' do
      state.save

      expect(File.exist?(global_paths.ledger_sync_state_file)).to be true
    end

    it 'writes valid JSON' do
      state.save

      content = JSON.parse(File.read(global_paths.ledger_sync_state_file), symbolize_names: true)
      expect(content[:schema_version]).to eq(1)
      expect(content[:ledger_head]).to eq('abc123')
      expect(content[:offline_claims].size).to eq(1)
    end

    it 'creates parent directories if needed' do
      FileUtils.rm_rf('/home/user/.eluent/test-repo')

      state.save

      expect(File.exist?(global_paths.ledger_sync_state_file)).to be true
    end

    it 'returns self for method chaining' do
      expect(state.save).to eq(state)
    end

    it 'can be loaded after saving (round-trip)' do
      state.save

      new_state = described_class.new(global_paths: global_paths, clock: clock)
      new_state.load

      expect(new_state.ledger_head).to eq('abc123')
      expect(new_state.last_pull_at).to eq(frozen_time)
      expect(new_state.offline_claims.first.atom_id).to eq('TSV4')
    end
  end

  # ===========================================================================
  # Pull/Push Tracking
  # ===========================================================================

  describe '#update_pull' do
    it 'sets last_pull_at to current time' do
      state.update_pull(head_sha: 'abc123')

      expect(state.last_pull_at).to eq(frozen_time)
    end

    it 'sets ledger_head to provided SHA' do
      state.update_pull(head_sha: 'abc123')

      expect(state.ledger_head).to eq('abc123')
    end

    it 'sets valid to true' do
      expect(state.valid?).to be false

      state.update_pull(head_sha: 'abc123')

      expect(state.valid?).to be true
    end

    it 'returns self for method chaining' do
      expect(state.update_pull(head_sha: 'abc123')).to eq(state)
    end

    context 'with invalid head_sha' do
      it 'raises ArgumentError when head_sha is nil' do
        expect { state.update_pull(head_sha: nil) }
          .to raise_error(ArgumentError, 'head_sha is required')
      end

      it 'raises ArgumentError when head_sha is empty string' do
        expect { state.update_pull(head_sha: '') }
          .to raise_error(ArgumentError, 'head_sha cannot be empty')
      end

      it 'raises ArgumentError when head_sha is whitespace only' do
        expect { state.update_pull(head_sha: '   ') }
          .to raise_error(ArgumentError, 'head_sha cannot be empty')
      end
    end

    context 'with edge case head_sha values' do
      it 'strips whitespace from head_sha' do
        state.update_pull(head_sha: '  abc123  ')

        expect(state.ledger_head).to eq('abc123')
      end

      it 'truncates extremely long head_sha to MAX_SHA_LENGTH' do
        long_sha = 'a' * 100
        state.update_pull(head_sha: long_sha)

        expect(state.ledger_head.length).to eq(described_class::MAX_SHA_LENGTH)
        expect(state.ledger_head).to eq('a' * 64)
      end
    end
  end

  describe '#update_push' do
    it 'sets last_push_at to current time' do
      state.update_push(head_sha: 'abc123')

      expect(state.last_push_at).to eq(frozen_time)
    end

    it 'sets ledger_head to provided SHA' do
      state.update_push(head_sha: 'abc123')

      expect(state.ledger_head).to eq('abc123')
    end

    it 'does not modify valid' do
      state.update_pull(head_sha: 'abc123') # Sets to true
      state.update_push(head_sha: 'def456')

      expect(state.valid?).to be true
    end

    it 'returns self for method chaining' do
      expect(state.update_push(head_sha: 'abc123')).to eq(state)
    end

    context 'with invalid head_sha' do
      it 'raises ArgumentError when head_sha is nil' do
        expect { state.update_push(head_sha: nil) }
          .to raise_error(ArgumentError, 'head_sha is required')
      end

      it 'raises ArgumentError when head_sha is empty string' do
        expect { state.update_push(head_sha: '') }
          .to raise_error(ArgumentError, 'head_sha cannot be empty')
      end
    end
  end

  # ===========================================================================
  # Offline Claim Management
  # ===========================================================================

  describe '#record_offline_claim' do
    let(:claim_time) { Time.utc(2026, 1, 20, 10, 0, 0) }

    it 'adds a claim to offline_claims' do
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)

      expect(state.offline_claims.size).to eq(1)
      claim = state.offline_claims.first
      expect(claim.atom_id).to eq('TSV4')
      expect(claim.agent_id).to eq('agent-1')
      expect(claim.claimed_at).to eq(claim_time)
    end

    it 'replaces existing claim for same atom' do
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-2', claimed_at: frozen_time)

      expect(state.offline_claims.size).to eq(1)
      expect(state.offline_claims.first.agent_id).to eq('agent-2')
    end

    it 'allows multiple claims for different atoms' do
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)
      state.record_offline_claim(atom_id: 'TSV5', agent_id: 'agent-1', claimed_at: frozen_time)

      expect(state.offline_claims.size).to eq(2)
    end

    it 'stores claim time as Time object in UTC' do
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)

      expect(state.offline_claims.first.claimed_at).to be_a(Time)
      expect(state.offline_claims.first.claimed_at).to eq(claim_time.utc)
    end

    it 'returns self for method chaining' do
      result = state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)

      expect(result).to eq(state)
    end

    context 'with invalid parameters' do
      it 'raises ArgumentError when atom_id is nil' do
        expect { state.record_offline_claim(atom_id: nil, agent_id: 'agent-1', claimed_at: claim_time) }
          .to raise_error(ArgumentError, 'atom_id is required')
      end

      it 'raises ArgumentError when atom_id is empty' do
        expect { state.record_offline_claim(atom_id: '', agent_id: 'agent-1', claimed_at: claim_time) }
          .to raise_error(ArgumentError, 'atom_id cannot be empty')
      end

      it 'raises ArgumentError when atom_id is whitespace only' do
        expect { state.record_offline_claim(atom_id: '   ', agent_id: 'agent-1', claimed_at: claim_time) }
          .to raise_error(ArgumentError, 'atom_id cannot be empty')
      end

      it 'raises ArgumentError when agent_id is nil' do
        expect { state.record_offline_claim(atom_id: 'TSV4', agent_id: nil, claimed_at: claim_time) }
          .to raise_error(ArgumentError, 'agent_id is required')
      end

      it 'raises ArgumentError when agent_id is empty' do
        expect { state.record_offline_claim(atom_id: 'TSV4', agent_id: '', claimed_at: claim_time) }
          .to raise_error(ArgumentError, 'agent_id cannot be empty')
      end

      it 'raises ArgumentError when claimed_at is not a Time' do
        expect { state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: '2026-01-20') }
          .to raise_error(ArgumentError, 'claimed_at must be a Time')
      end

      it 'raises ArgumentError when claimed_at is nil' do
        expect { state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: nil) }
          .to raise_error(ArgumentError, 'claimed_at must be a Time')
      end
    end

    context 'with edge case string values' do
      it 'strips whitespace from atom_id and agent_id' do
        state.record_offline_claim(atom_id: '  TSV4  ', agent_id: '  agent-1  ', claimed_at: claim_time)

        expect(state.offline_claims.first.atom_id).to eq('TSV4')
        expect(state.offline_claims.first.agent_id).to eq('agent-1')
      end

      it 'truncates extremely long atom_id to MAX_ATOM_ID_LENGTH' do
        long_id = 'a' * 300
        state.record_offline_claim(atom_id: long_id, agent_id: 'agent-1', claimed_at: claim_time)

        expect(state.offline_claims.first.atom_id.length).to eq(described_class::MAX_ATOM_ID_LENGTH)
      end

      it 'truncates extremely long agent_id to MAX_AGENT_ID_LENGTH' do
        long_id = 'b' * 300
        state.record_offline_claim(atom_id: 'TSV4', agent_id: long_id, claimed_at: claim_time)

        expect(state.offline_claims.first.agent_id.length).to eq(described_class::MAX_AGENT_ID_LENGTH)
      end

      it 'normalizes atom_id before de-duplication check' do
        state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)
        state.record_offline_claim(atom_id: '  TSV4  ', agent_id: 'agent-2', claimed_at: frozen_time)

        expect(state.offline_claims.size).to eq(1)
        expect(state.offline_claims.first.agent_id).to eq('agent-2')
      end
    end

    context 'when MAX_OFFLINE_CLAIMS is exceeded' do
      it 'drops oldest claims with warning' do
        # Fill to max + 10
        (described_class::MAX_OFFLINE_CLAIMS + 10).times do |i|
          state.record_offline_claim(atom_id: "TSV#{i}", agent_id: 'agent-1', claimed_at: claim_time + i)
        end

        expect(state.offline_claims.size).to eq(described_class::MAX_OFFLINE_CLAIMS)
        # Oldest claims (TSV0-TSV9) should be dropped
        expect(state.offline_claims.first.atom_id).to eq('TSV10')
      end

      it 'logs a warning when dropping claims' do
        described_class::MAX_OFFLINE_CLAIMS.times do |i|
          state.record_offline_claim(atom_id: "TSV#{i}", agent_id: 'agent-1', claimed_at: claim_time)
        end

        allow(state).to receive(:warn)
        state.record_offline_claim(atom_id: 'OVERFLOW', agent_id: 'agent-1', claimed_at: claim_time)

        expect(state).to have_received(:warn).with(/offline claims limit reached/)
      end
    end
  end

  describe '#clear_offline_claim' do
    let(:claim_time) { Time.utc(2026, 1, 20, 10, 0, 0) }

    before do
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time)
      state.record_offline_claim(atom_id: 'TSV5', agent_id: 'agent-1', claimed_at: claim_time)
    end

    it 'removes the specified claim' do
      state.clear_offline_claim(atom_id: 'TSV4')

      expect(state.offline_claims.size).to eq(1)
      expect(state.offline_claims.first.atom_id).to eq('TSV5')
    end

    it 'is a no-op if claim does not exist' do
      state.clear_offline_claim(atom_id: 'NONEXISTENT')

      expect(state.offline_claims.size).to eq(2)
    end

    it 'returns self for method chaining' do
      expect(state.clear_offline_claim(atom_id: 'TSV4')).to eq(state)
    end

    context 'with edge case values' do
      it 'handles nil atom_id gracefully (no-op)' do
        expect { state.clear_offline_claim(atom_id: nil) }.not_to raise_error
        expect(state.offline_claims.size).to eq(2)
      end

      it 'normalizes atom_id before matching' do
        state.clear_offline_claim(atom_id: '  TSV4  ')

        expect(state.offline_claims.size).to eq(1)
        expect(state.offline_claims.first.atom_id).to eq('TSV5')
      end
    end
  end

  describe '#offline_claims?' do
    it 'returns false when no offline claims' do
      expect(state.offline_claims?).to be false
    end

    it 'returns true when offline claims exist' do
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: frozen_time)

      expect(state.offline_claims?).to be true
    end
  end

  # ===========================================================================
  # Reset and Worktree Validity
  # ===========================================================================

  describe '#reset!' do
    before do
      state.update_pull(head_sha: 'abc123')
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: frozen_time)
      state.save
    end

    it 'clears all fields to defaults' do
      state.reset!

      expect(state.last_pull_at).to be_nil
      expect(state.last_push_at).to be_nil
      expect(state.ledger_head).to be_nil
      expect(state.valid?).to be false
      expect(state.offline_claims).to eq([])
    end

    it 'deletes the state file' do
      expect(File.exist?(global_paths.ledger_sync_state_file)).to be true

      state.reset!

      expect(File.exist?(global_paths.ledger_sync_state_file)).to be false
    end

    it 'is a no-op if file does not exist' do
      FileUtils.rm_f(global_paths.ledger_sync_state_file)

      expect { state.reset! }.not_to raise_error
    end

    it 'returns self for method chaining' do
      expect(state.reset!).to eq(state)
    end
  end

  describe '#invalidate!' do
    before do
      state.update_pull(head_sha: 'abc123')
    end

    it 'sets valid to false' do
      expect(state.valid?).to be true

      state.invalidate!

      expect(state.valid?).to be false
    end

    it 'returns self for method chaining' do
      expect(state.invalidate!).to eq(state)
    end
  end

  # ===========================================================================
  # Schema Migration (tested via load)
  # ===========================================================================

  describe 'schema migration' do
    it 'upgrades older schema versions during load' do
      File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                        schema_version: 0,
                                                        ledger_head: 'abc123'
                                                      ))
      state.load

      expect(state.schema_version).to eq(described_class::VERSION)
      expect(state.ledger_head).to eq('abc123')
    end

    it 'raises error for future schema versions during load' do
      File.write(global_paths.ledger_sync_state_file, JSON.generate(
                                                        schema_version: 999,
                                                        last_pull_at: frozen_time.iso8601
                                                      ))

      expect { state.load }
        .to raise_error(Eluent::Sync::LedgerSyncStateError, /newer than supported.*upgrade/i)
    end
  end

  # ===========================================================================
  # Serialization
  # ===========================================================================

  describe '#to_h' do
    before do
      state.update_pull(head_sha: 'abc123')
      state.update_push(head_sha: 'def456')
      state.record_offline_claim(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: frozen_time)
    end

    it 'returns all fields as a hash' do
      hash = state.to_h

      expect(hash[:schema_version]).to eq(1)
      expect(hash[:last_pull_at]).to eq(frozen_time.iso8601)
      expect(hash[:last_push_at]).to eq(frozen_time.iso8601)
      expect(hash[:ledger_head]).to eq('def456')
      expect(hash[:valid]).to be true
      expect(hash[:offline_claims].size).to eq(1)
    end

    it 'handles nil timestamps' do
      fresh_state = described_class.new(global_paths: global_paths, clock: clock)
      hash = fresh_state.to_h

      expect(hash[:last_pull_at]).to be_nil
      expect(hash[:last_push_at]).to be_nil
    end
  end

  # ===========================================================================
  # File Locking
  # ===========================================================================

  describe 'file locking' do
    it 'creates lock file during save' do
      state.save

      expect(File.exist?(global_paths.ledger_lock_file)).to be true
    end

    it 'creates lock file directory if needed' do
      FileUtils.rm_rf('/home/user/.eluent/test-repo')

      state.save

      expect(File.exist?(global_paths.ledger_lock_file)).to be true
    end
  end
end

# ==============================================================================
# LedgerSyncStateError
# ==============================================================================

RSpec.describe Eluent::Sync::LedgerSyncStateError do
  it 'inherits from Eluent::Error for consistent exception hierarchy' do
    expect(described_class.superclass).to eq(Eluent::Error)
  end
end

# ==============================================================================
# OfflineClaim
# ==============================================================================

RSpec.describe Eluent::Sync::OfflineClaim do
  let(:claim_time) { Time.utc(2026, 1, 20, 10, 0, 0) }
  let(:claim) { described_class.new(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: claim_time) }

  describe '#to_h' do
    it 'returns a hash with ISO8601 timestamp' do
      hash = claim.to_h

      expect(hash).to eq(
        atom_id: 'TSV4',
        agent_id: 'agent-1',
        claimed_at: '2026-01-20T10:00:00Z'
      )
    end

    it 'handles nil claimed_at gracefully' do
      claim_with_nil = described_class.new(atom_id: 'TSV4', agent_id: 'agent-1', claimed_at: nil)

      expect(claim_with_nil.to_h[:claimed_at]).to be_nil
    end
  end
end
