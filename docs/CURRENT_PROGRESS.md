# Ledger Branch Implementation Progress

**Last Updated**: 2026-01-20

This document tracks progress towards completing the Ledger Branch feature defined in `LEDGER_BRANCH.md`.

---

## Overview

| Phase | Status | Progress |
|-------|--------|----------|
| Phase 1: GlobalPaths Infrastructure | Complete | 100% |
| Phase 2: GitAdapter Extensions | Not Started | 0% |
| Phase 3: LedgerSyncer Core | Not Started | 0% |
| Phase 4: LedgerSyncState | Not Started | 0% |
| Phase 5: ConfigLoader Updates | Not Started | 0% |
| Phase 6: CLI Commands | Not Started | 0% |
| Phase 7: Daemon Integration | Not Started | 0% |
| Phase 8: ExecutionLoop Integration | Not Started | 0% |
| Phase 9: Stale Worktree Recovery | Not Started | 0% |
| Phase 10: Stale Claim Management | Not Started | 0% |

**Current State**: Phase 1 complete. Ready to start Phase 2.

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

- [ ] `lib/eluent/sync/git_adapter.rb` — Add methods:
  - [ ] `#branch_exists?(branch, remote:)`
  - [ ] `#create_orphan_branch(branch, initial_message:)`
  - [ ] `#checkout(branch, create:)`
  - [ ] `#worktree_list`
  - [ ] `#worktree_add(path:, branch:)`
  - [ ] `#worktree_remove(path:, force:)`
  - [ ] `#worktree_prune`
  - [ ] `#run_in_worktree(worktree_path, *args)`
  - [ ] `#fetch_branch(remote:, branch:, timeout:)`
  - [ ] `#push_branch(remote:, branch:, set_upstream:, timeout:)`
  - [ ] `#remote_ref_sha(remote:, branch:)`
  - [ ] `WorktreeError` exception
  - [ ] `BranchError` exception
  - [ ] `GitTimeoutError` exception

### Specs

- [ ] `spec/eluent/sync/git_adapter_spec.rb` — Extended specs for new methods

---

## Phase 3: LedgerSyncer Core

Core class for atomic claims, pull/push ledger, worktree management.

### Implementation

- [ ] `lib/eluent/sync/ledger_syncer.rb` — LedgerSyncer class with:
  - [ ] Constants: `LEDGER_BRANCH`, `MAX_RETRIES`, `BASE_BACKOFF_MS`, `MAX_BACKOFF_MS`, `JITTER_FACTOR`
  - [ ] Data types: `ClaimResult`, `SetupResult`, `SyncResult`
  - [ ] `#initialize(repository:, git_adapter:, global_paths:, remote:, max_retries:, clock:)`
  - [ ] `#available?`
  - [ ] `#online?`
  - [ ] `#healthy?`
  - [ ] `#setup!`
  - [ ] `#teardown!`
  - [ ] `#claim_and_push(atom_id:, agent_id:)`
  - [ ] `#pull_ledger`
  - [ ] `#push_ledger`
  - [ ] `#sync_to_main`
  - [ ] `#seed_from_main`
  - [ ] `#release_claim(atom_id:)`
  - [ ] `#worktree_stale?`
  - [ ] `#recover_stale_worktree!`
  - [ ] `#reconcile_offline_claims!`
  - [ ] Backoff with jitter implementation

### Specs

- [ ] `spec/eluent/sync/ledger_syncer_spec.rb`

---

## Phase 4: LedgerSyncState

Persists last sync times, offline claims, and worktree validity to disk.

### Implementation

- [ ] `lib/eluent/sync/ledger_sync_state.rb` — LedgerSyncState class with:
  - [ ] `VERSION` constant
  - [ ] Attributes: `last_pull_at`, `last_push_at`, `ledger_head`, `worktree_valid`, `offline_claims`, `schema_version`
  - [ ] `#initialize(global_paths:, clock:)`
  - [ ] `#load`
  - [ ] `#save`
  - [ ] `#update_pull(head_sha:)`
  - [ ] `#update_push(head_sha:)`
  - [ ] `#record_offline_claim(atom_id:, agent_id:, claimed_at:)`
  - [ ] `#clear_offline_claim(atom_id:)`
  - [ ] `#reset!`
  - [ ] `#migrate!`
  - [ ] File locking during save
  - [ ] Corruption recovery

### Specs

- [ ] `spec/eluent/sync/ledger_sync_state_spec.rb`

---

## Phase 5: ConfigLoader Updates

Add `sync:` config section with ledger options.

### Implementation

- [ ] `lib/eluent/storage/config_loader.rb` — Add to DEFAULT_CONFIG:
  - [ ] `sync.ledger_branch`
  - [ ] `sync.auto_claim_push`
  - [ ] `sync.claim_retries`
  - [ ] `sync.claim_timeout_hours`
  - [ ] `sync.offline_mode`
  - [ ] `sync.network_timeout`
  - [ ] `sync.global_path_override`
  - [ ] Validation for new config options

### Specs

- [ ] `spec/eluent/storage/config_loader_spec.rb` — Extended specs for sync config

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

- [ ] `lib/eluent/sync/ledger_syncer.rb` — Add recovery logic:
  - [ ] Enhanced `#worktree_stale?` detection
  - [ ] `#recover_stale_worktree!` implementation
  - [ ] Auto-recovery in `#claim_and_push` and `#pull_ledger`

### Specs

- [ ] `spec/eluent/sync/ledger_syncer_spec.rb` — Stale worktree recovery specs

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

*To be filled in as implementation progresses.*
