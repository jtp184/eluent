# Ledger Branch Implementation Plan

## Summary

Implement a dedicated git branch (`eluent-sync`) for fast-syncing the `.eluent/` directory, enabling atomic claim operations that prevent race conditions when multiple agents coordinate work.

## Terminology

- **Agent**: A process executing work on atoms. Each agent has a unique identifier (default: hostname). Multiple agents may run on different machines or as separate processes on the same machine.
- **Atom**: A unit of work in Eluent's dependency graph. Each atom represents a discrete task that can be claimed, executed, and completed by an agent. Atoms have unique IDs and track their status (`open`, `in_progress`, `closed`).
- **Claim**: The act of an agent reserving an atom for exclusive work. A claimed atom has `status: in_progress` and `assignee: <agent_id>`.
- **Ledger**: The `.eluent/` directory contents—configuration, atom definitions, and work status. This is what gets synced between agents.
- **Main branch**: The repository's default branch (auto-detected via `git symbolic-ref refs/remotes/origin/HEAD`). Used interchangeably with "main" throughout this document.
- **Stale claim**: A claim that remains `in_progress` beyond its expected lifetime, typically due to agent crash or network partition.
- **Worktree**: A git feature allowing multiple working directories to share the same repository. Used here to maintain a separate checkout of the `eluent-sync` branch.

## Quick Start

Once implemented, enable ledger sync for a repository:

```yaml
# 1. Enable in config (.eluent/config.yml)
sync:
  ledger_branch: eluent-sync
```

```bash
# 2. Initialize (creates branch and worktree)
el sync --setup-ledger

# 3. Claim atoms atomically
el claim TSV4 --agent-id my-agent

# 4. Check status
el sync --status
```

## Architecture

```
Remote Repository
├── default branch      → code + .eluent/ (full repo)
└── eluent-sync         → .eluent/ only (lightweight sync branch)

Local
├── Working tree        → your current branch (feature work)
└── ~/.eluent/<repo_name>/.sync-worktree/
    └── .eluent/        → eluent-sync branch (separate git worktree)
```

The sync worktree contains **only** the `.eluent/` directory, making pull/push operations fast. This worktree is stored in your home directory so it's shared across all local clones of the same repository.

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Worktree location | `~/.eluent/<repo_name>/.sync-worktree/` | Shared across local clones of same repo |
| Branch contents | Entire `.eluent/` directory | Keeps all agent coordination data together |
| Initial setup | Seed from main branch | Ensures ledger starts with existing atom definitions |
| Work completion | Sync back to working tree | Code commits include updated ledger state |
| Offline behavior | Local-only claiming | Agents can work offline, sync when reconnected |
| Retry strategy | Exponential backoff with jitter | Prevents thundering herd on conflicts |
| Claim timeout | Configurable TTL (default: none) | Releases stale claims from crashed agents |

---

## Phase 1: GlobalPaths Infrastructure

**New file**: `lib/eluent/storage/global_paths.rb`

```ruby
module Eluent
  module Storage
    class GlobalPaths
      GLOBAL_DIR = File.expand_path('~/.eluent')

      def initialize(repo_name:)
      def global_dir                  # ~/.eluent/
      def repo_dir                    # ~/.eluent/<repo_name>/
      def sync_worktree_dir           # ~/.eluent/<repo_name>/.sync-worktree/
      def ledger_sync_state_file      # ~/.eluent/<repo_name>/.ledger-sync-state
      def ledger_lock_file            # ~/.eluent/<repo_name>/.ledger.lock
      def ensure_directories!         # Create all required directories
      def valid?                      # All paths are accessible and writable
    end
  end
end
```

### Edge Cases: GlobalPaths

| Scenario | Behavior |
|----------|----------|
| Home directory unwritable (`~/.eluent/` creation fails) | Raise `GlobalPathsError` with actionable message suggesting `XDG_DATA_HOME` override or permission fix |
| `repo_name` contains path separators or special chars | Sanitize to filesystem-safe name (replace `/\:*?"<>\|` with `_`), warn if sanitization applied |
| NFS/network filesystem for home directory | Detect via `stat -f` and warn about potential atomicity issues; recommend local override |
| Disk quota exceeded during `ensure_directories!` | Raise `GlobalPathsError` with specific error; don't leave partial directories |
| Multiple users sharing same machine | Paths are user-scoped (`~/.eluent/`), no conflict; document that sudo vs non-sudo are separate |
| `XDG_DATA_HOME` override | Support `$XDG_DATA_HOME/eluent/` as alternative to `~/.eluent/` for Linux standards compliance |

---

## Phase 2: GitAdapter Extensions

**Modified file**: `lib/eluent/sync/git_adapter.rb`

Add methods:

```ruby
# Branch operations
def branch_exists?(branch, remote: nil)
def create_orphan_branch(branch, initial_message:)
def checkout(branch, create: false)

# Worktree operations
def worktree_list
def worktree_add(path:, branch:)
def worktree_remove(path:, force: false)
def worktree_prune

# Execute git commands in a specific worktree
def run_git_in_worktree(worktree_path, *args)

# Ledger operations (network-aware with timeouts)
def fetch_branch(remote:, branch:, timeout: 30)
def push_branch(remote:, branch:, set_upstream: false, timeout: 30)
def remote_branch_sha(remote:, branch:)  # Get SHA via ls-remote (no fetch required)
```

New exceptions: `WorktreeError`, `BranchError`, `GitTimeoutError`

### Edge Cases: GitAdapter Extensions

| Scenario | Behavior |
|----------|----------|
| Branch name invalid (spaces, `..`, starts with `-`) | Validate branch name before git operations; raise `BranchError` with reason |
| `worktree_add` path already exists but isn't a worktree | Check for existing directory; if present but not valid worktree, raise `WorktreeError` suggesting manual cleanup |
| `worktree_remove` on path that doesn't exist | Return success (idempotent); log debug message |
| `worktree_remove` while directory is in use (open files) | Retry with backoff (3 attempts); if still locked, raise `WorktreeError` with PID info if available |
| Network timeout during `fetch_branch` | Raise `GitTimeoutError` after configured timeout (default 30s); distinguish from auth failure |
| SSH key passphrase required | Detect interactive prompt and fail fast with message to use ssh-agent |
| Worktree path too long (Windows 260 char limit) | Validate path length on Windows; suggest shorter repo name |
| Git version too old for worktree features | Check `git --version` >= 2.5.0; raise `GitError` with upgrade instructions |
| Concurrent `worktree_add` for same path | Use file lock during worktree operations; return existing worktree if created by another process |

---

## Phase 3: LedgerSyncer Core

**New file**: `lib/eluent/sync/ledger_syncer.rb`

```ruby
module Eluent
  module Sync
    class LedgerSyncer
      LEDGER_BRANCH = 'eluent-sync'
      MAX_RETRIES = 5
      BASE_BACKOFF_MS = 100
      MAX_BACKOFF_MS = 5000         # Cap backoff to prevent excessive waits
      JITTER_FACTOR = 0.2           # ±20% randomization to prevent thundering herd

      ClaimResult = Data.define(:success, :error, :claimed_by, :retries, :offline_claim)
      SetupResult = Data.define(:success, :error, :created_branch, :created_worktree)
      SyncResult = Data.define(:success, :error, :conflicts, :changes_applied)

      def initialize(repository:, git_adapter:, global_paths:, remote:, max_retries:, clock: Time)

      # State checks
      def available?                # Worktree exists and remote branch exists
      def online?                   # Remote reachable (via `git ls-remote` probe with timeout)
      def healthy?                  # available? && !worktree_stale? && state file valid

      # Setup
      def setup!                    # Create orphan branch + worktree
      def teardown!                 # Remove worktree and clean up state (for reset scenarios)

      # Core operations
      def claim_and_push(atom_id:, agent_id:)  # Atomic claim with retry
      def pull_ledger               # Pull eluent-sync branch to worktree
      def push_ledger               # Push worktree changes to eluent-sync
      def sync_to_main              # Copy .eluent/ from worktree → working tree
      def seed_from_main            # Copy .eluent/ from working tree → worktree (initial setup)
      def release_claim(atom_id:)   # Explicitly release a claim (set status back to open)

      # Recovery
      def worktree_stale?
      def recover_stale_worktree!
      def reconcile_offline_claims! # Push any claims made while offline
    end
  end
end
```

### Atomic Claim Workflow

```
                           claim_and_push(atom_id, agent_id)
                                        │
                    ┌───────────────────┼───────────────────┐
                    │                   ▼                   │
                    │   ┌───────────────────────────────┐   │
                    │   │ 1. pull_ledger()              │   │
                    │   │    Get latest .eluent/        │   │
                    │   └───────────────┬───────────────┘   │
                    │                   ▼                   │
                    │   ┌───────────────────────────────┐   │
                    │   │ 2. Check atom status          │   │
                    │   │    Already claimed?           │   │
                    │   └───────────────┬───────────────┘   │
                    │           ┌───────┴───────┐           │
                    │           ▼               ▼           │
                    │      [by another]     [available]     │
                    │           │               │           │
                    │           ▼               ▼           │
                    │     Return error   ┌─────────────┐    │
                    │                    │ 3. Update   │    │
                    │                    │    atom     │    │
                    │                    └──────┬──────┘    │
                    │                           ▼           │
                    │                    ┌─────────────┐    │
                    │                    │ 4. Commit   │    │
 Retry with         │                    └──────┬──────┘    │
 backoff            │                           ▼           │
 (max 5)            │                    ┌─────────────┐    │
                    │                    │ 5. Push     │    │
                    │                    └──────┬──────┘    │
                    │                   ┌───────┴───────┐   │
                    │                   ▼               ▼   │
                    │              [rejected]      [success]│
                    │                   │               │   │
                    └───────────────────┘               ▼   │
                                               Return success
```

**Push rejection**: Occurs when another agent pushed first (remote ref differs from local). The retry loop re-pulls to see if the atom was claimed by someone else.

**Max retries exhausted**: Returns `ClaimResult(success: false, error: "Max retries exceeded", retries: 5)`. Does not raise an exception—caller decides how to handle.

**Offline mode**: When `!online?` (remote unreachable), the claim is recorded locally only. The agent can work, and changes sync when connectivity returns. The `offline_claim` field in `ClaimResult` indicates whether this was an offline claim.

### Edge Cases: LedgerSyncer

| Scenario | Behavior |
|----------|----------|
| Atom doesn't exist | Return `ClaimResult(success: false, error: "Atom not found: {id}")` |
| Atom already claimed by same agent | Return `ClaimResult(success: true)` (idempotent) |
| Atom in terminal state (closed, discard) | Return `ClaimResult(success: false, error: "Cannot claim atom in {status} state")` |
| Network failure mid-push (partial) | Verify remote state after timeout; if push succeeded, return success; otherwise retry |
| Clock skew between agents | Use server-side timestamps when available; document that clocks within 5s are assumed |
| Thundering herd (10+ agents retry simultaneously) | Apply jitter (±20%) to backoff; consider distributed lock for high-contention scenarios |
| Offline claim conflicts on reconnect | `reconcile_offline_claims!` detects conflicts; return list of atoms that couldn't be claimed |
| `pull_ledger` fails mid-operation | Leave worktree in previous state; don't apply partial changes |
| Worktree `.eluent/` is empty after pull | Valid state (no atoms defined yet); don't treat as error |
| `sync_to_main` called with dirty working tree | Warn and proceed; document that local changes may be overwritten |
| Remote branch force-pushed (history rewritten) | Detect via SHA mismatch; offer `--force-resync` option to reset local state |
| `seed_from_main` when working tree has no `.eluent/` | Create empty ledger structure; this is the bootstrap case |
| Setup called twice | Return `SetupResult(success: true, created_branch: false, created_worktree: false)` (idempotent) |
| Setup on shallow clone | Detect and fail with message; ledger sync requires full clone |

### Backoff Strategy

```
attempt 1: 100ms  ±20ms  (jitter)
attempt 2: 200ms  ±40ms
attempt 3: 400ms  ±80ms
attempt 4: 800ms  ±160ms
attempt 5: 1600ms ±320ms
         ────────────────
total max: ~3.5 seconds before giving up
```

The jitter prevents synchronized retries when multiple agents fail simultaneously.

---

## Phase 4: LedgerSyncState

**New file**: `lib/eluent/sync/ledger_sync_state.rb`

```ruby
module Eluent
  module Sync
    class LedgerSyncState
      VERSION = 1                   # Schema version for future migrations

      attr_reader :last_pull_at, :last_push_at, :ledger_head, :worktree_valid
      attr_reader :offline_claims, :schema_version

      def initialize(global_paths:, clock: Time)
      def load                      # Load state from file; returns self
      def save                      # Persist state to file atomically
      def update_pull(head_sha:)    # Record successful pull with current time
      def update_push(head_sha:)    # Record successful push with current time
      def record_offline_claim(atom_id:, agent_id:, claimed_at:)
      def clear_offline_claim(atom_id:)
      def reset!                    # Clear all state; start fresh
      def migrate!                  # Upgrade schema if version mismatch
    end
  end
end
```

State file location: `~/.eluent/<repo_name>/.ledger-sync-state` (JSON format)

### Edge Cases: LedgerSyncState

| Scenario | Behavior |
|----------|----------|
| State file corrupted (invalid JSON) | Log warning, call `reset!`, start fresh; don't fail operation |
| State file truncated (incomplete write) | Same as corrupted; atomic writes prevent most cases |
| Schema version newer than code supports | Refuse to load; suggest upgrading eluent |
| Schema version older than current | Call `migrate!` to upgrade in place |
| `ledger_head` points to non-existent commit | Mark `worktree_valid: false`; trigger recovery on next operation |
| `last_pull_at` in the future (clock adjusted backward) | Accept it; use monotonic comparison where possible |
| Concurrent writes to state file | Use file locking (`File.flock`) during save |
| State file deleted while running | Recreate on next save; treat as fresh start |
| Offline claims list grows unbounded | Limit to 1000 entries; oldest claims dropped with warning |
| `offline_claims` contains atom that was deleted | Skip during reconciliation; log and remove from list |

---

## Phase 5: ConfigLoader Updates

**Modified file**: `lib/eluent/storage/config_loader.rb`

Add to `DEFAULT_CONFIG` in `.eluent/config.yml`:

```yaml
sync:
  ledger_branch: null        # Branch name for ledger sync (null = feature disabled)
  auto_claim_push: true      # Push to remote immediately after claiming an atom
  claim_retries: 5           # Max retry attempts on push conflict
  claim_timeout_hours: null  # Hours before stale claims are auto-released (null = never)
  offline_mode: local        # Behavior when remote is unreachable:
                             #   'local' = claim locally, sync later
                             #   'fail'  = reject claim if can't reach remote
  network_timeout: 30        # Seconds to wait for git network operations
  global_path_override: null # Override ~/.eluent/ location (e.g., for CI)
```

**Enabling ledger sync**: Set `ledger_branch: 'eluent-sync'` (or any valid branch name). When `null`, all ledger sync features are disabled and claims are local-only. This is the default.

### Edge Cases: ConfigLoader

| Scenario | Behavior |
|----------|----------|
| `ledger_branch` set to invalid git branch name | Validate on load; raise `ConfigError` with reason |
| `claim_retries` set to 0 | Treat as 1 (minimum); log warning |
| `claim_retries` set to very high value (>100) | Cap at 100; log warning about potential delays |
| `offline_mode` set to unrecognized value | Raise `ConfigError` listing valid options |
| `claim_timeout_hours` set to very low value (<1) | Allow but warn; short timeouts may cause premature releases |
| Config changed between operations | Reload config on each operation; document that mid-operation changes may cause inconsistency |
| `ledger_branch` toggled from set to null | Existing worktree orphaned; `el sync --cleanup-ledger` removes it |
| `global_path_override` points to non-existent directory | Create it; same behavior as default path |
| Config file unreadable mid-operation | Use cached config; log warning |

---

## Phase 6: CLI Commands

### New file: `lib/eluent/cli/commands/claim.rb`

```bash
el claim ATOM_ID                # Claim atom (uses ledger sync if configured)
el claim ATOM_ID --agent-id X   # Claim as specific agent (default: hostname)
el claim ATOM_ID --offline      # Force local-only claim, skip remote sync
el claim ATOM_ID --force        # Claim even if already claimed (steal claim)
el claim ATOM_ID --quiet        # Suppress success output (for scripting)
```

**Exit codes** (defined in `application.rb`):
- `0` - Claim successful
- `1` - Atom already claimed by another agent
- `2` - Max retries exhausted (persistent conflict)
- `3` - Ledger sync not configured (when `--offline` not specified and sync required)
- `4` - Atom not found
- `5` - Atom in terminal state (cannot claim)

### Modified file: `lib/eluent/cli/commands/sync.rb`

```bash
el sync --setup-ledger        # One-time setup: create eluent-sync branch + worktree
el sync --ledger-only         # Fast sync: only pull/push .eluent/, skip code
el sync --cleanup-ledger      # Remove ledger worktree and state (disable feature)
el sync --reconcile           # Push pending offline claims, report conflicts
el sync --force-resync        # Reset local ledger state from remote (destructive)
el sync --status              # Show ledger sync health and pending offline claims
```

### Modified file: `lib/eluent/cli/application.rb`

Add exit code constants for claim operations:

```ruby
module ExitCodes
  CLAIM_CONFLICT = 1       # Atom already claimed by another agent
  CLAIM_RETRIES = 2        # Max retries exhausted
  LEDGER_NOT_CONFIGURED = 3
  ATOM_NOT_FOUND = 4
  ATOM_TERMINAL = 5        # Cannot claim atom in closed/discard state
end
```

### Edge Cases: CLI Commands

| Scenario | Behavior |
|----------|----------|
| `el claim` with invalid ATOM_ID format | Validate format; exit 4 with message |
| `el claim` when not in git repository | Exit with error suggesting to run in repo root |
| `el claim --force` on atom claimed by different agent | Steal claim; log warning with previous assignee |
| `el claim --offline` when ledger sync not configured | Proceed normally (already local-only); no error |
| `el sync --setup-ledger` when remote unreachable | Fail with network error; setup requires remote |
| `el sync --setup-ledger` when branch already exists on remote | Attach to existing branch; don't overwrite |
| `el sync --cleanup-ledger` with uncommitted ledger changes | Warn and require `--force` flag to proceed |
| `el sync --reconcile` with many offline claims | Process in batches; show progress bar |
| `el sync --force-resync` | Destructive; require `--yes` flag or interactive confirmation |
| `el sync --status` when offline | Show cached state with "last synced at X" indicator |
| Ctrl+C during claim operation | Clean up partial state via signal handler; don't leave corrupt worktree |
| Running multiple `el claim` in parallel (same machine) | File lock serializes claims; second process waits for lock |

---

## Phase 7: Daemon Integration

**Modified file**: `lib/eluent/daemon/command_router.rb`

Add to COMMANDS: `claim`, `ledger_sync`

```ruby
def handle_claim(args, id)
  # args: { repo_path:, atom_id:, agent_id: }
  # Returns: { success:, error:, claimed_by:, retries: }

def handle_ledger_sync(args, id)
  # args: { repo_path:, action: 'pull' | 'push' | 'setup' | 'status' | 'reconcile' }
  # Returns: { success:, error:, action:, details: }
```

The daemon maintains a `LedgerSyncer` instance per repository (created on first use, reused for subsequent requests to the same repo).

### Edge Cases: Daemon Integration

| Scenario | Behavior |
|----------|----------|
| Daemon receives claim for unknown repo | Return error with `repo_not_found`; suggest running setup |
| Daemon's LedgerSyncer instance becomes stale | Detect via `healthy?`; recreate instance |
| Concurrent claims from multiple daemon clients | Serialize via per-repo mutex; queue requests |
| Daemon restarts mid-claim | Client receives connection error; retry is safe (claims are idempotent for same agent) |
| `repo_path` doesn't match any cached syncer | Create new syncer; log first-use message |
| Memory pressure (many repos) | LRU eviction of LedgerSyncer instances; state persisted in files |
| Client disconnects mid-operation | Complete operation server-side; result lost but operation succeeded |
| Daemon receives malformed args | Validate args; return structured error with field names |

---

## Phase 8: ExecutionLoop Integration

**Modified file**: `lib/eluent/agents/execution_loop.rb`

Add `ledger_syncer` dependency and integrate atomic claims:

```ruby
ClaimOutcome = Data.define(:success, :reason, :offline, :degraded, :error) do
  def initialize(success:, reason: nil, offline: false, degraded: false, error: nil)
    super
  end
end

def initialize(repository:, executor:, configuration:, git_adapter: nil, ledger_syncer: nil)

def claim_atom(atom)
  if ledger_syncer&.available?
    # Atomic remote claim with conflict detection
    result = ledger_syncer.claim_and_push(atom_id: atom.id, agent_id: configuration.agent_id)
    return ClaimOutcome.new(success: false, reason: result.error, offline: result.offline_claim) unless result.success
    repository.load!  # Reload to pick up any changes from other agents
    ClaimOutcome.new(success: true, offline: result.offline_claim)
  else
    # Fallback: local-only claim (no remote sync)
    atom.claim!(agent_id: configuration.agent_id)
    ClaimOutcome.new(success: true, offline: true)
  end
rescue LedgerSyncError => e
  # Network/worktree issues: fall back to local if config allows
  if configuration.offline_mode == 'local'
    atom.claim!(agent_id: configuration.agent_id)
    ledger_syncer&.state&.record_offline_claim(atom_id: atom.id, agent_id: configuration.agent_id, claimed_at: Time.now)
    ClaimOutcome.new(success: true, offline: true, degraded: true, error: e.message)
  else
    ClaimOutcome.new(success: false, reason: e.message)
  end
end

def sync_after_work
  return unless ledger_syncer&.available?

  result = ledger_syncer.push_ledger     # Push updated atom status to eluent-sync
  ledger_syncer.sync_to_main             # Copy .eluent/ changes to working tree
  log_sync_result(result)
  # Existing code sync continues here (git add, commit, push for code changes)
rescue LedgerSyncError => e
  # Log but don't fail work completion; ledger will sync later
  warn "el: ledger sync failed: #{e.message}"
end

def release_claim_on_failure(atom)
  # Called when work fails and we want to release the claim
  ledger_syncer&.release_claim(atom_id: atom.id) if ledger_syncer&.available?
  atom.release!
rescue LedgerSyncError
  # Best effort; claim may remain until timeout
end
```

**Flow**: When an agent completes work, `sync_after_work` first pushes ledger changes to the fast-sync branch, then copies those changes to the working tree so they're included in the code commit.

### Edge Cases: ExecutionLoop Integration

| Scenario | Behavior |
|----------|----------|
| `claim_atom` succeeds remotely but `repository.load!` fails | Claim is valid; retry load or proceed with stale local state |
| `claim_atom` returns offline_claim=true | Agent proceeds; user informed that claim is local-only |
| Claim succeeds but atom was modified by another agent (merge) | `load!` picks up changes; work proceeds on potentially updated atom |
| `sync_after_work` fails (network down) | Log warning; work is done, ledger syncs later |
| Agent crashes after claim, before work completion | Claim remains in_progress; stale claim mechanism handles (if `claim_timeout_hours` configured) |
| Agent claims atom, another agent steals with `--force` | First agent's work may be lost; document as expected behavior |
| `release_claim_on_failure` fails | Claim remains; will timeout eventually (if configured) |
| Ledger syncer unavailable mid-execution | Fall back to local operations; reconcile when available |
| Atom deleted remotely while agent is working | Agent continues; on sync, completed work for non-existent atom is logged and discarded |
| Agent ID collision (two agents with same hostname) | Undefined behavior; document requirement for unique agent IDs |

---

## Phase 9: Stale Worktree Recovery

A worktree becomes "stale" when it exists on disk but is no longer valid. This can happen when:
- The worktree directory exists but `.git` file is missing or corrupted
- The `eluent-sync` branch was deleted on the remote
- The worktree's HEAD ref points to a non-existent commit

**Detection**: `worktree_stale?` checks for these conditions before operations.

**Recovery**:
```ruby
def recover_stale_worktree!
  git_adapter.worktree_remove(path: worktree_path, force: true)
  git_adapter.worktree_prune      # Clean up git's internal worktree list
  ensure_worktree!                # Recreate fresh worktree
end
```

**When called**: Automatically invoked at the start of `claim_and_push` and `pull_ledger` if staleness is detected. This makes the syncer self-healing.

### Edge Cases: Stale Worktree Recovery

| Scenario | Behavior |
|----------|----------|
| Worktree directory exists but is empty | Detect as stale; recover |
| `.git` file exists but points to non-existent main repo | Detect via `git rev-parse`; recover with warning |
| Worktree contains uncommitted changes | Log warning with diff; changes lost during recovery |
| Recovery fails (permissions, disk full) | Raise `WorktreeError`; don't leave partial state |
| Branch deleted on remote but exists locally | Detect on next fetch; warn and offer to recreate or cleanup |
| Main repository moved/deleted | Worktree unusable; `worktree_stale?` returns true; guide user to re-setup |
| Worktree locked by another process | Retry with backoff; if persistent, inform user with PID |
| Recovery during active claim operation | Serialize via lock; recovery blocks claim until complete |
| Worktree on different filesystem than main repo | Supported; some git versions have bugs, detect and warn |

---

## Phase 10: Stale Claim Management

**New capability in LedgerSyncer**

Stale claims occur when agents crash or lose connectivity. Without cleanup, atoms remain locked forever.

```ruby
# Add to LedgerSyncer class
def release_stale_claims(older_than:)
  # Find atoms where:
  #   status == :in_progress
  #   AND updated_at < older_than
  # For each, set status = :open, assignee = nil
  # Commit with message: "Auto-release stale claim on {id} (was: {agent})"
  # Returns: Array of released atom IDs
end

def stale_claims(older_than:)
  # Query only, don't modify
  # Returns: Array of Atom objects matching stale criteria
end
```

### Automatic Release Strategy

When `claim_timeout_hours` is configured:

1. On each `pull_ledger`, scan for stale claims
2. If `updated_at + claim_timeout_hours < Time.now`, the claim is stale
3. Release stale claims with commit message: `"Auto-release stale claim on {id} (was: {agent})"`
4. Log released claims for auditability

### Edge Cases: Stale Claim Management

| Scenario | Behavior |
|----------|----------|
| Agent still working but slow (false positive timeout) | Agent loses claim; must re-claim or abandon work |
| Clock skew makes claim appear stale | Use conservative threshold (add buffer); document clock sync requirement |
| Two agents detect same stale claim simultaneously | Both try to release; second push fails, retries, sees already released |
| Stale claim on atom that was modified (metadata change) | `updated_at` reset; no longer stale |
| `claim_timeout_hours: null` (disabled) | Never auto-release; manual release only |
| Legitimate long-running work | Use longer timeout or disable; alternatively, agent can "heartbeat" by touching atom |
| Stale claim release during agent's push | Agent's push fails; re-pull shows released; agent must decide to re-claim or abandon |

### Heartbeat Pattern (Optional)

For long-running work, agents can periodically "touch" their claimed atoms to prevent false-positive stale detection:

```ruby
# Add to LedgerSyncer class
def heartbeat(atom_id:)
  # Update atom's updated_at without changing other fields
  # Commit with message: "Heartbeat for {id}"
  # Prevents stale claim detection for active work
end
```

**Usage**: Call every `claim_timeout_hours / 2` during long-running work.

---

## Files Summary

### New Files (4)

| File | Purpose |
|------|---------|
| `lib/eluent/storage/global_paths.rb` | Manages paths under `~/.eluent/<repo>/` for worktree and state files |
| `lib/eluent/sync/ledger_syncer.rb` | Core class: atomic claims, pull/push ledger, worktree management |
| `lib/eluent/sync/ledger_sync_state.rb` | Persists last sync times, offline claims, and worktree validity to disk |
| `lib/eluent/cli/commands/claim.rb` | `el claim` command implementation |

### Modified Files (6)

| File | Changes |
|------|---------|
| `lib/eluent/sync/git_adapter.rb` | Add branch and worktree git operations |
| `lib/eluent/storage/config_loader.rb` | Add `sync:` config section with ledger options |
| `lib/eluent/cli/commands/sync.rb` | Add `--setup-ledger`, `--ledger-only`, `--cleanup-ledger`, `--reconcile`, `--force-resync`, `--status` flags |
| `lib/eluent/cli/application.rb` | Register `claim` command and add `ExitCodes` constants |
| `lib/eluent/daemon/command_router.rb` | Add `claim` and `ledger_sync` command handlers |
| `lib/eluent/agents/execution_loop.rb` | Integrate `LedgerSyncer` for atomic claims via `claim_atom` method |

---

## Implementation Order

Each phase builds on the previous. Complete all tests for a phase before moving to the next.

| Order | Phases | Deliverable |
|-------|--------|-------------|
| 1 | 1-2 | GlobalPaths + GitAdapter extensions (foundation) |
| 2 | 3-4 | LedgerSyncer + LedgerSyncState (core sync logic) |
| 3 | 5 | Config options for sync behavior |
| 4 | 6 | CLI: `el claim` command, `el sync` flags |
| 5 | 7 | Daemon: command handlers for claim/sync |
| 6 | 8 | ExecutionLoop integration (automatic for agents) |
| 7 | 9 | Stale worktree detection and recovery |
| 8 | 10 | Stale claim management and auto-release |

---

## Verification

### Manual Testing Scenario

Two agents (A and B) competing to claim the same atom:

```bash
# One-time setup (creates eluent-sync branch and worktree)
el sync --setup-ledger

# Terminal 1: Agent A claims atom TSV4
el claim TSV4 --agent-id agent-a
# → Success: "Claimed TSV4"

# Terminal 2: Agent B tries to claim the same atom
el claim TSV4 --agent-id agent-b
# → Error (exit 1): "TSV4 already claimed by agent-a"

# Terminal 1: Agent A completes and syncs
el close TSV4 --reason "done"
el sync --ledger-only              # Fast push of ledger only

# Terminal 2: Agent B claims the next available atom
el ready                           # List available atoms
el claim TSV5 --agent-id agent-b   # Claim a different one
```

### Automated Tests

```bash
bundle exec rspec spec/eluent/storage/global_paths_spec.rb  # GlobalPaths
bundle exec rspec spec/eluent/sync/                          # All sync specs
bundle exec rspec spec/eluent/cli/commands/claim_spec.rb     # Claim command
bundle exec rspec spec/integration/ledger_sync_spec.rb       # Multi-agent scenarios
```

### Integration Test Scenarios

These scenarios must be covered by integration tests before the feature ships:

| Scenario | Setup | Expected Outcome |
|----------|-------|------------------|
| Concurrent claim race | Two processes claim same atom simultaneously | Exactly one succeeds; other gets `ClaimConflict` |
| Offline claim and reconcile | Claim while offline, reconnect | Claim succeeds on reconcile or reports conflict |
| Stale worktree recovery | Corrupt `.git` file in worktree, then claim | Auto-recovers; claim succeeds |
| Claim timeout | Claim, advance clock past timeout | Stale claim auto-released |
| Force-push recovery | Rewrite remote history | Detects mismatch; `--force-resync` recovers |
| Network partition during push | Kill network mid-push | Verifies remote state; retries or fails cleanly |

---

## Edge Case Summary

This section consolidates the critical edge cases that MUST be tested before release.

### P0: Data Loss Prevention

| Risk | Mitigation | Test |
|------|------------|------|
| Worktree recovery loses uncommitted changes | Log diff before recovery; require `--force` for destructive recovery | Unit test with dirty worktree |
| Offline claims lost on crash | Persist to state file immediately; sync on next opportunity | Kill process mid-claim, verify state file |
| Force-resync destroys local state | Require explicit confirmation; backup before destructive ops | Integration test with `--force-resync` |

### P1: Race Conditions

| Risk | Mitigation | Test |
|------|------------|------|
| Two agents claim same atom | Git push atomicity; retry loop detects loser | Parallel claim integration test |
| Stale claim released while agent pushes | Agent's push fails; must re-claim | Timing-based integration test |
| Concurrent worktree access (same machine) | File locking in GlobalPaths | Fork-based concurrency test |

### P2: Network Resilience

| Risk | Mitigation | Test |
|------|------------|------|
| Network timeout during claim | Configurable timeout; clear error message | Mock slow network |
| Partial push (connection dropped) | Verify remote state; retry if unclear | Network fault injection |
| Remote unreachable for extended period | Offline mode; reconcile queue | Multi-hour offline simulation |

### P3: State Corruption

| Risk | Mitigation | Test |
|------|------------|------|
| State file corrupted | Reset and warn; don't fail operation | Truncate state file, verify recovery |
| Worktree `.git` file corrupted | Detect via health check; auto-recover | Corrupt `.git`, verify recovery |
| Config changed mid-operation | Reload on each operation; atomic reads | Modify config during claim |

### P4: Usability

| Risk | Mitigation | Test |
|------|------------|------|
| Confusing error messages | Structured errors with suggested actions | Manual review of all error paths |
| Silent failures | Log all operations; warn on degraded mode | Audit log output coverage |
| Orphaned worktree after disable | `--cleanup-ledger` command | Disable and re-enable feature |

---

## Glossary of Errors

| Error | Meaning | User Action |
|-------|---------|-------------|
| `BranchError` | Invalid branch name or branch operation failed | Check `ledger_branch` config; verify remote access |
| `ClaimConflict` | Atom already claimed by another agent | Choose different atom or use `--force` |
| `ConfigError` | Invalid configuration value | Check `.eluent/config.yml` syntax and values |
| `GitError` | Git version too old or git command failed | Ensure git >= 2.5.0; check git installation |
| `GitTimeoutError` | Network operation timed out | Check connectivity; increase `network_timeout` |
| `GlobalPathsError` | Cannot create/access `~/.eluent/` | Check permissions; set `global_path_override` |
| `LedgerSyncError` | General sync failure | Check `el sync --status`; run `--force-resync` if needed |
| `StaleWorktreeError` | Worktree needs recovery | Automatic recovery attempted; if persistent, manual cleanup |
| `WorktreeError` | Git worktree operation failed | Run `el sync --cleanup-ledger`, then `--setup-ledger` |

---

## Future Considerations

These are **out of scope** for initial implementation but may be valuable for future iterations:

| Feature | Use Case | Complexity |
|---------|----------|------------|
| Distributed lock service | High contention (>10 concurrent agents) | High |
| Claim lease renewal | Explicit lease model instead of timeout-based release | Medium |
| CRDTs | Metadata that needs conflict-free concurrent editing | High |
| Webhook notifications | Push-based claim change notification | Medium |
| Claim transfer | Hand off claim without release/re-claim race | Low |
| Audit log | Debugging multi-agent coordination issues | Low |

---

*Document version: 1.0*
