# Ledger Branch Implementation Progress

**Last Updated**: 2026-01-20

This document tracks progress towards completing the Ledger Branch feature defined in `LEDGER_BRANCH.md`.

---

## Overview

| Phase | Status | Progress |
|-------|--------|----------|
| Phase 1: GlobalPaths Infrastructure | Complete | 100% |
| Phase 2: GitAdapter Extensions | Complete | 100% |
| Phase 3: LedgerSyncer Core | Complete | 100% |
| Phase 4: LedgerSyncState | Complete | 100% |
| Phase 5: ConfigLoader Updates | Complete | 100% |
| Phase 6: CLI Commands | Not Started | 0% |
| Phase 7: Daemon Integration | Not Started | 0% |
| Phase 8: ExecutionLoop Integration | Not Started | 0% |
| Phase 9: Stale Worktree Recovery | Not Started | 0% |
| Phase 10: Stale Claim Management | Not Started | 0% |

**Current State**: Phase 5 complete. Ready to start Phase 6.

---

## Phase 1: GlobalPaths Infrastructure

Manages paths under `~/.eluent/<repo>/` for worktree and state files.

### Implementation

- [x] `lib/eluent/storage/global_paths.rb` — GlobalPaths class with:
  - [x] `GLOBAL_DIR_NAME` constant (`.eluent`)
  - [x] `#initialize(repo_name:)`
  - [x] `#global_dir`
  - [x] `#repo_dir`
  - [x] `#sync_worktree_dir`
  - [x] `#ledger_sync_state_file`
  - [x] `#ledger_lock_file`
  - [x] `#ensure_directories!`
  - [x] `#valid?`
  - [x] XDG_DATA_HOME support
  - [x] Repo name sanitization
  - [x] `GlobalPathsError` exception class

### Specs

- [x] `spec/eluent/storage/global_paths_spec.rb` (35 examples, 0 failures)

---

## Phase 2: GitAdapter Extensions

Add branch and worktree git operations.

### Implementation

- [x] `lib/eluent/sync/git_adapter.rb` — Add methods:
  - [x] `#branch_exists?(branch, remote:)`
  - [x] `#create_orphan_branch(branch, initial_message:)`
  - [x] `#checkout(branch, create:)`
  - [x] `#worktree_list`
  - [x] `#worktree_add(path:, branch:)`
  - [x] `#worktree_remove(path:, force:)`
  - [x] `#worktree_prune`
  - [x] `#run_git_in_worktree(worktree_path, *args)`
  - [x] `#fetch_branch(remote:, branch:, timeout:)`
  - [x] `#push_branch(remote:, branch:, set_upstream:, timeout:)`
  - [x] `#remote_branch_sha(remote:, branch:)`
  - [x] `WorktreeError` exception
  - [x] `BranchError` exception (with `validate_branch_name!` class method)
  - [x] `GitTimeoutError` exception
  - [x] `WorktreeInfo` data class for worktree list results

### Specs

- [x] `spec/eluent/sync/git_adapter_spec.rb` — Extended specs for new methods (89 examples, 0 failures)

---

## Phase 3: LedgerSyncer Core

Core class for atomic claims, pull/push ledger, worktree management.

### Implementation

- [x] `lib/eluent/sync/ledger_syncer.rb` — LedgerSyncer class with:
  - [x] Constants: `LEDGER_BRANCH`, `MAX_RETRIES`, `BASE_BACKOFF_MS`, `MAX_BACKOFF_MS`, `JITTER_FACTOR`
  - [x] Data types: `ClaimResult`, `SetupResult`, `SyncResult`
  - [x] `#initialize(repository:, git_adapter:, global_paths:, remote:, max_retries:, clock:)`
  - [x] `#available?`
  - [x] `#online?`
  - [x] `#healthy?`
  - [x] `#setup!`
  - [x] `#teardown!`
  - [x] `#claim_and_push(atom_id:, agent_id:)`
  - [x] `#pull_ledger`
  - [x] `#push_ledger`
  - [x] `#sync_to_main`
  - [x] `#seed_from_main`
  - [x] `#release_claim(atom_id:)`
  - [x] `#worktree_stale?`
  - [x] `#recover_stale_worktree!`
  - [x] `#reconcile_offline_claims!` (placeholder for Phase 4)
  - [x] Backoff with jitter implementation
- [x] `lib/eluent/sync/concerns/ledger_worktree.rb` — Worktree management concern
- [x] `lib/eluent/sync/concerns/ledger_atom_operations.rb` — Atom operations concern
- [x] `LedgerSyncerError` exception class

### Specs

- [x] `spec/eluent/sync/ledger_syncer_spec.rb` (71 examples, 0 failures)

### Implementation Notes

- Extracted worktree and atom operations into separate concerns to keep class size manageable
- `reconcile_offline_claims!` returns empty array as a placeholder until Phase 4 (LedgerSyncState) is implemented
- Auto-recovery of stale worktrees is built into `claim_and_push` and `pull_ledger`
- Backoff strategy uses exponential backoff with ±20% jitter to prevent thundering herd

---

## Phase 4: LedgerSyncState

Persists last sync times, offline claims, and worktree validity to disk.

### Implementation

- [x] `lib/eluent/sync/ledger_sync_state.rb` — LedgerSyncState class with:
  - [x] `VERSION` constant (schema versioning for migrations)
  - [x] `MAX_OFFLINE_CLAIMS` constant (prevents unbounded growth)
  - [x] Attributes: `last_pull_at`, `last_push_at`, `ledger_head`, `worktree_valid`, `offline_claims`, `schema_version`
  - [x] `#initialize(global_paths:, clock:)`
  - [x] `#load` (with corruption recovery)
  - [x] `#save` (atomic write via temp file + rename)
  - [x] `#update_pull(head_sha:)`
  - [x] `#update_push(head_sha:)`
  - [x] `#record_offline_claim(atom_id:, agent_id:, claimed_at:)`
  - [x] `#clear_offline_claim(atom_id:)`
  - [x] `#offline_claims?` (predicate for pending claims)
  - [x] `#reset!`
  - [x] `#migrate!` (schema version checking and future migration support)
  - [x] `#invalidate_worktree!`
  - [x] `#exists?`
  - [x] `#to_h` (JSON serialization)
  - [x] File locking during save (`with_lock` using `File.flock`)
  - [x] Corruption recovery (warns and resets on invalid JSON)
  - [x] `LedgerSyncStateError` exception class

### Specs

- [x] `spec/eluent/sync/ledger_sync_state_spec.rb` (59 examples, 0 failures)

### Implementation Notes

- State file stored as JSON at `~/.eluent/<repo>/.ledger-sync-state`
- Atomic writes using temp file + rename pattern
- File locking via separate lock file (gracefully handles FakeFS and unsupported filesystems)
- Offline claims limited to 1000 entries, oldest dropped with warning
- Schema versioning for future migrations (rejects files with newer versions)
- Corrupted files trigger reset with warning, never fail operations

---

## Phase 5: ConfigLoader Updates

Add `sync:` config section with ledger options.

### Implementation

- [x] `lib/eluent/storage/config_loader.rb` — Add to DEFAULT_CONFIG:
  - [x] `sync.ledger_branch` (validated via `BranchError.valid_branch_name?`)
  - [x] `sync.auto_claim_push` (boolean, default: true)
  - [x] `sync.claim_retries` (1-100, default: 5)
  - [x] `sync.claim_timeout_hours` (nullable float, warns if < 1)
  - [x] `sync.offline_mode` (enum: 'local' | 'fail', default: 'local')
  - [x] `sync.network_timeout` (5-300 seconds, default: 30)
  - [x] `sync.global_path_override` (nullable path, expands ~)
  - [x] Validation for new config options
- [x] `ConfigError` exception class for validation failures

### Specs

- [x] `spec/eluent/storage/config_loader_spec.rb` — Extended specs for sync config (39 examples, 0 failures)

### Implementation Notes

- Branch name validation reuses `BranchError.valid_branch_name?` from GitAdapter
- Numeric validations use warnings for out-of-range values and clamp to valid range
- `offline_mode` raises `ConfigError` for invalid values (not correctable)
- Invalid branch names raise `ConfigError` (not correctable)
- Empty strings treated as nil (disabled) for optional string values

---

## Phase 6: CLI Commands

`el claim` command and `el sync` flags.

### Implementation

- [ ] `lib/eluent/cli/commands/claim.rb` — Claim command with:
  - [ ] `el claim ATOM_ID`
  - [ ] `--agent-id` option
  - [ ] `--offline` option
  - [ ] `--force` option
  - [ ] `--quiet` option
  - [ ] Exit codes (0-5)
- [ ] `lib/eluent/cli/commands/sync.rb` — Add flags:
  - [ ] `--setup-ledger`
  - [ ] `--ledger-only`
  - [ ] `--cleanup-ledger`
  - [ ] `--reconcile`
  - [ ] `--force-resync`
  - [ ] `--status`
- [ ] `lib/eluent/cli/application.rb` — Add:
  - [ ] Register `claim` command
  - [ ] `ExitCodes` module constants

### Specs

- [ ] `spec/eluent/cli/commands/claim_spec.rb`
- [ ] `spec/eluent/cli/commands/sync_spec.rb` — Extended specs for new flags

---

## Phase 7: Daemon Integration

Command handlers for claim/sync.

### Implementation

- [ ] `lib/eluent/daemon/command_router.rb` — Add:
  - [ ] `claim` to COMMANDS
  - [ ] `ledger_sync` to COMMANDS
  - [ ] `#handle_claim(args, id)`
  - [ ] `#handle_ledger_sync(args, id)`
  - [ ] Per-repo LedgerSyncer instance management

### Specs

- [ ] `spec/eluent/daemon/command_router_spec.rb` — Extended specs for new handlers

---

## Phase 8: ExecutionLoop Integration

Integrate `LedgerSyncer` for atomic claims.

### Implementation

- [ ] `lib/eluent/agents/execution_loop.rb` — Add:
  - [ ] `ClaimOutcome` data type
  - [ ] `ledger_syncer` dependency in `#initialize`
  - [ ] `#claim_atom(atom)` method
  - [ ] `#sync_after_work` method
  - [ ] `#release_claim_on_failure(atom)` method
  - [ ] Fallback to local claiming when syncer unavailable
  - [ ] Offline claim recording

### Specs

- [ ] `spec/eluent/agents/execution_loop_spec.rb` — Extended specs for ledger integration

---

## Phase 9: Stale Worktree Recovery

Detect and recover from stale worktrees.

### Implementation

- [x] `lib/eluent/sync/ledger_syncer.rb` — Add recovery logic:
  - [x] Enhanced `#worktree_stale?` detection
  - [x] `#recover_stale_worktree!` implementation
  - [x] Auto-recovery in `#claim_and_push` and `#pull_ledger`

### Specs

- [x] `spec/eluent/sync/ledger_syncer_spec.rb` — Stale worktree recovery specs

**Note:** Basic stale worktree recovery was implemented as part of Phase 3.

---

## Phase 10: Stale Claim Management

Auto-release stale claims from crashed agents.

### Implementation

- [ ] `lib/eluent/sync/ledger_syncer.rb` — Add:
  - [ ] `#release_stale_claims(older_than:)`
  - [ ] `#stale_claims(older_than:)`
  - [ ] `#heartbeat(atom_id:)` (optional)
  - [ ] Auto-release during `#pull_ledger` when `claim_timeout_hours` configured

### Specs

- [ ] `spec/eluent/sync/ledger_syncer_spec.rb` — Stale claim management specs

---

## Integration Tests

- [ ] `spec/integration/ledger_sync_spec.rb` — Multi-agent scenarios:
  - [ ] Concurrent claim race
  - [ ] Offline claim and reconcile
  - [ ] Stale worktree recovery
  - [ ] Claim timeout
  - [ ] Force-push recovery
  - [ ] Network partition during push

---

## Implementation Notes

### Phase 3 Notes

- Used Ruby 3.2+ `Data.define` for immutable result types (`ClaimResult`, `SetupResult`, `SyncResult`)
- Extracted concerns for worktree management and atom operations to keep the main class under 250 lines
- The `claim_and_push` retry loop implements exponential backoff with jitter per the spec
- Stale worktree detection checks: directory existence, .git file validity, and branch matching
- File operations use `FileUtils.rm_f` for atomic deletion
