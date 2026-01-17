# Eluent Implementation Plan

**CLI Command**: `el`
**Ruby Version**: 4.0.1
**Storage**: JSONL files in `.eluent/` per repo, committed to git
**Cross-repo**: Shared registry at `~/.eluent/repos.jsonl`, supports inter-repo dependencies

---

## Terminology

| Term | Definition |
|------|------------|
| **Atom** | The fundamental work item (task, bug, feature, etc.) |
| **Bond** | A dependency relationship between two atoms |
| **Molecule** | A container or root atom with child atoms |
| **Formula** | A template for creating molecules with variables and structured dependencies |
| **Phase** | Whether an atom is **persistent** (synced to git) or **ephemeral** (local-only, git-ignored) |
| **Ready** | An atom with no blocking dependencies, available for work |
| **Abstract type** | An atom type excluded from ready work queries (e.g., formulae don't appear in `el ready`) |

See `docs/MEOW.md` for the complete Molecular Expression of Work specification.

---

## Architecture Overview

```
Eluent
├── Models         # Atom, Bond, Comment, Formula
├── Lifecycle      # Status, Transition, ReadinessCalculator
├── Graph          # DependencyGraph, CycleDetector, BlockingResolver
├── Storage        # JsonlRepository, Indexer, Serializers, EphemeralStore
├── Sync           # GitAdapter, MergeEngine, ConflictResolver, SyncState
├── Registry       # RepoRegistry, RepoContext, IdGenerator
├── Daemon         # Server (Unix sockets), Protocol, CommandRouter
├── CLI            # Application, Commands, OutputFormatter, Middleware
├── Formulas       # Parser, VariableResolver, Instantiator, Distiller, Composer
├── Compaction     # Compactor, Summarizer, Restorer
├── Plugins        # PluginManager, PluginContext, Hooks, GemLoader
└── Agents         # AgentExecutor, ClaudeExecutor, OpenAIExecutor
```
---

## Data Storage (`.eluent/`)

```
.eluent/
├── config.yaml         # Repository-level configuration
├── data.jsonl          # Atoms, Bonds, Comments, etc. (one JSON per line)
├── ephemeral.jsonl     # Local-only ephemeral items (git-ignored)
├── formulas/           # Formula definitions (YAML)
├── plugins/            # Local plugin scripts (.rb)
└── .sync-state         # Last sync metadata (JSON)
```

**.sync-state format**:
```json
{
  "last_sync_at": "2025-01-15T10:30:00Z",
  "base_commit": "abc123...",
  "local_head": "def456...",
  "remote_head": "789ghi..."
}
```

**config.yaml schema**:
```yaml
repo_name: eluent           # Repository identifier used in atom IDs
defaults:
  priority: 2               # Default priority for new atoms (1-5)
  issue_type: task          # Default atom type
ephemeral:
  cleanup_days: 7           # Auto-prune ephemeral items older than this
compaction:
  tier1_days: 30            # Tier 1 compaction after 30 days
  tier2_days: 90            # Tier 2 compaction after 90 days
```

**ID Format**: `{repo_name}-{base62_random}.{child}.{grandchild}...`

ID generation requirements:
- **Source**: Cryptographically secure random bytes (64 bits minimum)
- **Encoding**: Base62 (a-zA-Z0-9) for URL-safe, compact identifiers
- **Length**: ~11 characters for 64-bit entropy
- **Child IDs**: Arbitrary strings appended with `.` delimiter; must be unique within parent scope

**Examples**:
- `eluent-3kTm9vXpQ2z` — Root atom
- `eluent-3kTm9vXpQ2z.1` — First child (numeric)
- `eluent-3kTm9vXpQ2z.1.3` — Third grandchild of first child
- `eluent-3kTm9vXpQ2z.docs` — Child using semantic name
- `eluent-3kTm9vXpQ2z.docs.guide` — Nested semantic naming
---

## CLI Commands

```
el init                          # Initialize .eluent/ in current repo
el create [options]              # Create work item (-i for interactive)
el list [filters]                # List items with filters
el show ID                       # Show detailed item info
el update ID [options]           # Update work item fields directly
el close ID --reason=TEXT        # Close work item
el reopen ID                     # Reopen closed item
el ready [filters] [--sort=POLICY]  # Show ready-to-work items
el dep add|remove|list|tree|check   # Dependency management
el comment add|list              # Comment management
el discard ID|list|restore|prune # Soft deletion management
el formula list|show|instantiate|distill|compose|attach  # Templates
el sync [--pull-only|--push-only]  # Git-based sync
el daemon start|stop|status      # Daemon management (explicit start)
el config [local|global] show|set|get # Configuration
el plugin [name] list|install|enable|disable|hook # Plugin management
```

**Interactive Mode**: By default, commands with missing data (necessary fields not provided as arguments, etc.) launches TTY prompt for guided input.

**Structured Output Mode**: `--robot` (universal modifier) emits structured JSON output for any command. When `--robot` is set:
- Output is machine-parseable JSON
- Interactive prompts are disabled; commands that require input return an error instead
- Rich formatting (colors, spinners, tables) is disabled

### Ready Work Options

The `el ready` command supports:
- **Sort policies** (`--sort=POLICY`):
  - `priority` — Highest priority first, then oldest (default)
  - `oldest` — Creation date ascending
  - `hybrid` — Recent items (48h) by priority, older by age (prevents starvation)
- **Filters**:
  - `--type=TYPE` — Filter by work item type
  - `--exclude-type=TYPE` — Exclude specific types (e.g., `ephemeral`, `chore`)
  - `--assignee=USER` — Filter by assignee
  - `--label=LABEL` — Filter by label
  - `--priority=LEVEL` — Filter by priority level

### Update Command

`el update ID [options]` modifies atom fields:
- `--title=TEXT` — Update title
- `--description=TEXT` — Update description
- `--priority=LEVEL` — Update priority (1-5)
- `--type=TYPE` — Change atom type
- `--assignee=USER` — Assign/reassign
- `--label=LABEL` — Add label (repeatable)
- `--remove-label=LABEL` — Remove label
- `--status=STATUS` — Change status directly
- `--persist` — Convert ephemeral atom to persistent (moves from `ephemeral.jsonl` to `data.jsonl`)

### Discard Command

`el discard` provides soft deletion with recovery:

```bash
el discard ID              # Set atom status to 'discard' (soft delete)
el discard list            # List all discarded atoms
el discard restore ID      # Restore discarded atom to previous status
el discard prune           # Permanently delete old discards (default: >30 days)
el discard prune --all     # Permanently delete all discards immediately
el discard prune --ephemeral  # Permanently delete discarded ephemeral items
```

**Workflow**: Discarded atoms are excluded from `el list` and `el ready` by default. Use `el list --include-discarded` to see them.

---

## Key Files to Create

### Phase 1: Foundation
| File | Purpose |
|------|---------|
| `lib/eluent/models/atom.rb` | Core Atom entity with all fields |
| `lib/eluent/models/bond.rb` | Bond entity with all dependency types |
| `lib/eluent/models/comment.rb` | Append-only discussion |
| `lib/eluent/storage/jsonl_repository.rb` | JSONL persistence with locking |
| `lib/eluent/storage/indexer.rb` | In-memory index for fast lookups |
| `lib/eluent/storage/serializers/atom_serializer.rb` | Atom JSON serialization |
| `lib/eluent/storage/serializers/bond_serializer.rb` | Bond JSON serialization |
| `lib/eluent/registry/id_generator.rb` | Repo-aware Base62-encoded 64-bit random ID generation |
| `lib/eluent/cli/application.rb` | Main CLI entry point |
| `lib/eluent/cli/commands/init.rb` | Initialize .eluent/ |
| `lib/eluent/cli/commands/create.rb` | Create work items |
| `lib/eluent/cli/commands/list.rb` | List with filters |
| `lib/eluent/cli/commands/show.rb` | Show item details |
| `lib/eluent/cli/commands/update.rb` | Update work item fields |
| `lib/eluent/cli/commands/close.rb` | Close work item with reason |
| `lib/eluent/cli/commands/reopen.rb` | Reopen closed item |
| `lib/eluent/cli/commands/config.rb` | Configuration management |
| `exe/el` | CLI executable |

### Phase 2: Graph Operations
| File | Purpose |
|------|---------|
| `lib/eluent/graph/dependency_graph.rb` | DAG structure |
| `lib/eluent/graph/cycle_detector.rb` | Prevent cycles |
| `lib/eluent/graph/blocking_resolver.rb` | Transitive blocking for all dep types |
| `lib/eluent/lifecycle/status.rb` | Status enum (open, in_progress, blocked, deferred, closed, discard) |
| `lib/eluent/lifecycle/transition.rb` | State machine |
| `lib/eluent/lifecycle/readiness_calculator.rb` | Ready work query with type exclusions |
| `lib/eluent/cli/commands/ready.rb` | Show ready items with sort policies |
| `lib/eluent/cli/commands/dep.rb` | Dependency management |
| `lib/eluent/cli/commands/comment.rb` | Comment add/list management |
| `lib/eluent/cli/commands/discard.rb` | Soft deletion (list/restore/prune) |

### Phase 3: Sync and Daemon
| File | Purpose |
|------|---------|
| `lib/eluent/sync/git_adapter.rb` | Git operations wrapper |
| `lib/eluent/sync/merge_engine.rb` | 3-way merge |
| `lib/eluent/sync/pull_first_orchestrator.rb` | Pull-first sync flow |
| `lib/eluent/sync/sync_state.rb` | .sync-state file handling |
| `lib/eluent/registry/repo_registry.rb` | Cross-repo registry (~/.eluent/repos.jsonl) |
| `lib/eluent/daemon/server.rb` | Unix socket server |
| `lib/eluent/daemon/protocol.rb` | Length-prefixed JSON protocol |
| `lib/eluent/daemon/command_router.rb` | Route to handlers |
| `lib/eluent/cli/commands/sync.rb` | Sync command |
| `lib/eluent/cli/commands/daemon.rb` | Daemon management |

### Phase 4: Formulas and Compaction
| File | Purpose |
|------|---------|
| `lib/eluent/models/formula.rb` | Template definition |
| `lib/eluent/formulas/parser.rb` | YAML formula parsing |
| `lib/eluent/formulas/variable_resolver.rb` | Variable substitution ({{var}} syntax) |
| `lib/eluent/formulas/instantiator.rb` | Create items from template |
| `lib/eluent/formulas/distiller.rb` | Extract template from work |
| `lib/eluent/formulas/composer.rb` | Combine formulas (sequential/parallel/conditional) |
| `lib/eluent/compaction/compactor.rb` | Tier 1/2 compaction |
| `lib/eluent/compaction/summarizer.rb` | Summarize content for compaction |
| `lib/eluent/compaction/restorer.rb` | Restore original content from git history |
| `lib/eluent/cli/commands/formula.rb` | Formula commands (list/show/instantiate/distill/compose/attach) |

### Phase 5: Extensions and AI
| File | Purpose |
|------|---------|
| `lib/eluent/plugins/plugin_manager.rb` | Discovery and loading |
| `lib/eluent/plugins/plugin_context.rb` | Plugin DSL sandbox |
| `lib/eluent/plugins/hooks.rb` | Hook registration and invocation |
| `lib/eluent/agents/agent_executor.rb` | Abstract AI interface |
| `lib/eluent/agents/implementations/claude_executor.rb` | Claude integration |
| `lib/eluent/agents/implementations/openai_executor.rb` | OpenAI integration |
| `lib/eluent/agents/execution_loop.rb` | Standard agent work loop |

---

## Dependencies (Gemspec)

```ruby
# CLI
spec.add_dependency "tty-prompt", "~> 0.23"
spec.add_dependency "tty-table", "~> 0.12"
spec.add_dependency "tty-spinner", "~> 0.9"
spec.add_dependency "tty-box", "~> 0.7"
spec.add_dependency "tty-tree", "~> 0.4"
spec.add_dependency "tty-option", "~> 0.3"
spec.add_dependency "pastel", "~> 0.8"

# HTTP for AI
spec.add_dependency "httpx", "~> 1.3"
```

---

## Daemon Protocol

**Purpose**: The daemon coordinates concurrent reads/writes for multiple agents or CLI instances across repositories. It maintains authoritative in-memory state and serializes access to storage files. Not required for single-agent/single-repo use—CLI can operate directly on files.

**Transport**: Length-prefixed JSON over Unix sockets.
- **Length prefix**: 4-byte big-endian uint32 (message size in bytes)
- **Socket path**: `~/.eluent/daemon.sock`

**Request format**:
```json
{ "cmd": "list", "args": {"type": "task"}, "id": "req-123" }
```

**Success response**:
```json
{ "id": "req-123", "status": "ok", "data": {...} }
```

**Error response**:
```json
{ "id": "req-123", "status": "error", "error": {"code": "NOT_FOUND", "message": "Atom not found: eluent-xyz"} }
```

**Error codes**: `NOT_FOUND`, `INVALID_REQUEST`, `CONFLICT`, `STORAGE_ERROR`, `INTERNAL_ERROR`

---

## Error Codes Reference

| Code | HTTP-equiv | Description |
|------|------------|-------------|
| `NOT_FOUND` | 404 | Item/resource does not exist |
| `INVALID_REQUEST` | 400 | Malformed request or invalid parameters |
| `CONFLICT` | 409 | Operation conflicts with current state |
| `CYCLE_DETECTED` | 422 | Dependency would create cycle |
| `SELF_REFERENCE` | 422 | Item cannot depend on itself |
| `STORAGE_ERROR` | 500 | File system or storage failure |
| `TIMEOUT` | 504 | Operation exceeded time limit |
| `ENCODING_ERROR` | 400 | Invalid UTF-8 or encoding issue |
| `VALIDATION_ERROR` | 422 | Value fails validation (enum, pattern) |
| `INTERNAL_ERROR` | 500 | Unexpected error |

---

## Dependency Types

Blocking dependency types

| Type | Blocking | Semantics |
|------|----------|-----------|
| `blocks` | Yes | Source cannot start until target closes |
| `parent-child` | Yes | Source belongs to target; parent blocking cascades to children |
| `conditional-blocks` | Yes | Source runs only if target fails (close_reason indicates failure) |
| `waits-for` | Yes | Source waits for target AND all target's children to close |

Non-blocking (informational) types:

| Type | Semantics |
|------|-----------|
| `related` | Loosely connected work |
| `duplicates` | Source duplicates target |
| `discovered-from` | Source found while working on target |
| `replies-to` | Source is a response to target |

The `BlockingResolver` must handle all blocking types transitively.

---

## Sync Strategy (Pull-First)

1. Load local state
2. Fetch remote state from git
3. Load base state (last sync point)
4. 3-way merge with conflict resolution
   - Scalars: Last-Write-Wins (by updated_at)
   - Sets (labels): Union
   - Comments: Append + deduplicate
5. Apply merged result locally
6. Commit and push

**Resurrection rule**: Edit wins over delete (prevents silent data loss)

---

## Ephemeral Work Items

Work items can be created in two phases:

**Persistent Phase** (default):
- Stored in `.eluent/data.jsonl`
- Synced to git
- Full audit trail preserved
- Use for: planned work, features, bugs, releases

**Ephemeral Phase**:
- Stored in `.eluent/ephemeral.jsonl` (git-ignored, local-only)
- NOT synced to git or shared storage
- Persists locally across sessions (survives CLI/daemon restarts)
- Automatic cleanup after configurable duration (default: 7 days)
- Use for: grunt work, diagnostics, patrols, operational checks 

**Usage**:
```bash
el create --ephemeral --title "Debug session"
el formula instantiate release-checks --ephemeral
```

**Cleanup**: Ephemeral items older than the configured duration are automatically pruned on any `el` command execution. Manual cleanup: `el discard prune --ephemeral`.

**Phase Transitions**:
- `el update ID --persist` — Convert ephemeral item to persistent (moves to main storage)
- Ephemeral items can be closed normally; they remain in `ephemeral.jsonl` until auto-cleanup or manual prune

---

## Cross-Repository Dependencies

Cross-repo dependencies allow work items to reference items in other repositories.

**ID Format**: Cross-repo IDs use the full `{repo_name}-{hash}` format, where `repo_name` is unique across all registered repos.

**Repository Registry** (`~/.eluent/repos.jsonl`):
```json
{"name": "frontend", "path": "/code/frontend", "remote": "git@..."}
{"name": "backend", "path": "/code/backend", "remote": "git@..."}
```

**Resolution Strategy**:
1. Parse dependency target ID to extract repo name
2. Look up repo in registry
3. If defined: resolve path and load item
4. Or fail gracefully

**Sync Behavior**:
- Local repo syncs only its own items, maintains dep references to other repos without syncing their data

**Features**:
- Cross-repo blocking dependencies and ready work calculation
- Multi-project formulas and ephemerals instantiation

---

## Extension System

**Plugin sources** (in order):
1. `.eluent/plugins/*.rb` (project local)
2. `~/.eluent/plugins/*.rb` (user global)
3. `eluent-*` gems (installed)

**Plugin DSL**:
```ruby
Eluent::Plugins.register "my_plugin" do
  # Lifecycle hooks
  before_create { |ctx| ... }    # Called before item creation
  after_create { |ctx| ... }     # Called after item creation
  before_close { |ctx| ... }     # Called before item closure
  after_close { |ctx| ... }      # Called after item closure
  on_status_change { |ctx| ... } # Called on any status transition
  on_sync { |ctx| ... }          # Called after sync completes

  # Custom CLI commands
  command "mycommand", description: "..." do |ctx|
    # ctx.repo - repository instance
    # ctx.args - parsed arguments
    # ctx.output - output formatter
  end

  # Type registration
  register_issue_type :custom_type,
    required_fields: [:custom_field],
    abstract: true  # Abstract types (e.g., epic, molecule) are containers—excluded from `el ready`

  register_dependency_type :custom_dep,
    blocking: false,  # false by default, true affects readiness
    description: "Custom relationship description"
end
```

**Hook Context** (`ctx`):
- `ctx.item` — The work item being operated on
- `ctx.repo` — Repository instance for queries
- `ctx.changes` — Hash of changed fields (for updates)
- `ctx.halt!` — Abort the operation (before hooks only)

---

## AI Agent Integration

**Abstract interface**: `AgentExecutor` with tools:
- `list_items`, `show_item`, `create_item`, `update_item`
- `close_item`, `ready_work`, `add_dependency`, `add_comment`

**Reference implementations**:
- `ClaudeExecutor` (Claude API with function calling)
- `OpenAIExecutor` (OpenAI API with function calling)

**Execution loop**:
1. Query ready work (filtered by agent ID)
2. Claim atom (set in_progress + assignee)
3. Create work branch
4. Execute work plan via AI
5. Close issue with reason (or handle failure)
6. Create any needed follow-up items
7. Sync to git

---

## Verification Plan

### Automated Tests

1. **Unit tests**: RSpec for all models, storage, graph operations
2. **Integration tests**: CLI commands with temp directories
3. **Daemon tests**: Socket communication, concurrent access
4. **Sync tests**: 3-way merge scenarios with mock git

### Critical Test Cases

1. **Daemon concurrent access**:
   - Multiple CLI clients sending commands simultaneously
   - Read-write contention (one client listing while another creates)
   - Atomic state updates (no partial writes visible)
2. **Cycle detection edge cases**:
   - Complex DAG scenarios with multiple paths
   - Self-referential prevention
   - Cross-hierarchy dependencies
3. **Cross-repo dependency resolution**: Multi-repo sync scenarios
4. **Ephemeral cleanup**: Auto-cleanup after specified duration
5. **Ready work exclusions**: Verify blocked items don't appear in ready work by default
6. **Resurrection during sync**: Delete locally, edit remotely, verify edit wins
7. **All blocking types**: Test `blocks`, `parent-child`, `conditional-blocks`, `waits-for`
8. **Automatic molecule completion if configured** All children closed → molecule closes
9. **ID collision resistance**: Generate 10M IDs, verify no collisions (statistical test)
10. **Self-referential dependency rejection**: Verify A→A is rejected
11. **Cross-repo cycle detection**: A in repo1 → B in repo2 → A (cycle)
12. **Conditional-blocks skip behavior**: Target succeeds → dependent skipped
13. **Waits-for with dynamic children**: Add child after waits-for, verify blocking
14. **Ephemeral persistence transition**: During cleanup window, verify no data loss
15. **Formula variable collision in composition**: Same var, different defaults → warning
16. **Sync resurrection**: Local delete + remote edit → item restored
17. **Comment deduplication**: Same comment from two sources → single entry
18. **Daemon stale socket cleanup**: Old socket file → removed and recreated
19. **Unicode edge cases**: Emoji in titles, RTL text, combining characters

### Edge Cases and Error Handling

#### Dependency Edge Cases

**Self-referential Prevention**
- Reject `add_dependency(A, A, *)` for any dependency type
- Error: `SelfReferenceError`

**Transitive Cycle Detection**
- Check path existence in both directions before adding edge
- Example: A→B, B→C exists; reject C→A (creates A→B→C→A)
- Cross-repo cycles: Must traverse registry to check external repos
- Error: `CycleDetectedError` with cycle path for debugging

**Cross-Repo Dependency Resolution**
- If target repo not in registry: return `UnresolvedDependency` (blocking assumed)
- If target repo registered but unavailable: cache last-known state, warn user
- Network/filesystem errors: do not silently fail; surface to user

**Parent-Child Blocking Cascade**
- `BlockingResolver.blocked?(item)` must recursively check all ancestors
- Implementation: Walk `parent_id` chain until root or blocked ancestor found
- Performance: Cache ancestry at load time; invalidate on parent_id change

**Conditional-Blocks Failure Detection**
- Failure indicated by `close_reason` matching pattern: `/^(fail|error|abort)/i`
- Success: all other close_reason values OR nil/empty
- When target closes successfully: mark dependent as `status: closed, close_reason: "skipped: condition not met"`
- Skipped items excluded from ready work; can be reopened manually

**Waits-For Transitive Closure**
- Must wait for target AND all descendants of target (recursive)
- Dynamically added children: If child added to target after waits-for created, source automatically waits for new child
- Nested waits-for: A waits-for B, B waits-for C → A implicitly waits for C (transitive)
- Implementation: `BlockingResolver` computes closure at query time, not creation time

#### Status Edge Cases

**Blocked as Stored vs. Computed**
- Decision: Store `blocked` as explicit status field (not computed)
- Rationale: Simplifies sync merge (LWW on status field)
- Trade-off: Must update status on dependency changes; use hooks

**Status Transition Atomicity**
- All status changes must be atomic (single JSONL append)
- Concurrent transitions: Last-Write-Wins via `updated_at`
- Daemon serializes writes; CLI uses file locking

**Deferred Expiry Check**
- Evaluation: Lazy (at query time, not background job)
- `el ready` checks `defer_until < now` for each candidate
- No automatic status change; deferred items simply appear when ready
- Edge case: Clock skew between machines → use UTC everywhere

**Abstract Type List**
- Types excluded from `el ready` by default: `epic`, `molecule`, `formula`
- Custom abstract types registered via plugin: `abstract: true` flag
- `el ready --include-abstract` overrides for debugging

#### Sync Edge Cases

**Resurrection Rule (Edit vs. Delete)**
- Local: item in `discard` state; Remote: item edited (updated_at newer)
- Resolution: Restore item with remote edits; clear discard status
- Implementation: 3-way merge treats `discard` as "soft tombstone"

**Concurrent Deletion**
- Both local and remote delete same item → item stays deleted
- One deletes, one closes → closer timestamp wins (restore if edit newer)

**Dependency Merging**
- Strategy: Union + Deduplicate by (source_id, target_id, dependency_type)
- Ordering: Sort by created_at for deterministic order
- Conflict: Same edge with different metadata → merge metadata maps

**Comment Deduplication**
- Key: SHA256(author + created_at + content) → 16-char hex prefix
- Duplicate detection: On sync, skip comments with matching hash
- Ordering: Sort by created_at ascending (UTC)

**Metadata Preservation**
- Unknown keys in atom.metadata: Preserve during sync (union merge)
- Conflicting values for same key: LWW by updated_at
- Nested metadata: Not supported; flatten before sync

**Sync During Active Work**
- Items with `status: in_progress` and `assignee: local_agent`: warn before push
- Option: `--force` to push anyway; `--stash` to defer those items

#### Ephemeral Edge Cases

**Cleanup Trigger Points**
- CLI: On startup of any `el` command (after config load, before execution)
- Daemon: Every 60 seconds via background timer
- Cleanup order: Check timestamps first, then delete (avoid race with persist transition)

**Persistence Transition Atomicity**
- `el update ID --persist` must:
  1. Read from ephemeral.jsonl
  2. Write to data.jsonl
  3. Remove from ephemeral.jsonl
- Use file locking to prevent cleanup between steps 1-3

**Ephemeral Cross-Repo Dependencies**
- Ephemeral items CAN depend on persistent items (same or other repo)
- Persistent items CANNOT depend on ephemeral items (rejected at creation)
- Rationale: Ephemeral items may disappear; persistent deps must be stable

**Discard + Ephemeral Interaction**
- Discarded ephemeral items cleaned up by `el discard prune --ephemeral`
- Non-discarded ephemeral items cleaned up by age (cleanup_days config)
- Closed ephemeral items remain until age threshold OR manual prune

#### Formula Edge Cases

**Variable Validation Modes**
- Default: Lenient (unknown variables left as literal `{{name}}`)
- Strict mode (`--strict`): Unknown variables cause `UnknownVariableError`
- Enum validation: If `enum` specified, value must match one option
- Pattern validation: If `pattern` specified, value must match regex
- Validation order: Required check → Default apply → Enum check → Pattern check

**Composition Variable Scoping**
- Same variable in both formulas: Single prompt/value used for both
- Explicit scoping: `formula_a.version` and `formula_b.version` for disambiguation
- Collision detection: Warn if same variable has different defaults

**Conditional Composition Failure**
- Same as conditional-blocks: `close_reason` pattern matching
- Formula B runs only if Formula A's root item fails
- Skipped formulas: Root item created with `status: closed, close_reason: "skipped"`

**Formula Cycle Prevention**
- Before composition: Check if Formula B contains reference to Formula A
- Error: `FormulaRecursionError`
- Nested composition: Allowed but cycles still rejected

**Instantiation with Missing Parent**
- If `parent_id` provided but doesn't exist: `ParentNotFoundError`
- If parent exists but is closed: Warn, allow (formula may be for follow-up)

#### ID Generation Edge Cases

**Child ID Uniqueness Scope**
- Child IDs unique within parent scope only (not globally)
- Example: `eluent-abc.1` and `eluent-xyz.1` can both exist
- Full ID (including parent prefix) is globally unique

**Collision Detection and Recovery**
- On ID generation, check existence before write
- If collision detected (astronomically unlikely with 64-bit entropy): Generate new ID
- Log collision event for monitoring
- Statistical test: 10M IDs must have 0 collisions (implementation verification)

**ID Format Validation**
- Regex: `^[a-zA-Z0-9_-]+-[a-zA-Z0-9]{8,}(\.[a-zA-Z0-9_-]+)*$`
- Reject IDs not matching format on import/create
- Cross-repo IDs: Must include repo prefix

#### Compaction Edge Cases

**Compaction Trigger**
- Manual only: `el compact [--tier=1|2]`
- No automatic compaction (user controls when history is reduced)
- Sync does NOT trigger compaction

**Compaction Reversibility**
- Tier 1 → Tier 2: Original content lost (only Tier 1 summary preserved)
- Recovery: `el restore ID` retrieves from git history if available
- Implementation: Store pre-compaction content hash; query git for matching blob

**Dependency Preservation**
- Compacted items retain all inbound/outbound dependency edges
- Metadata on dependencies: Preserved (not compacted)
- Comments: Summarized to single "Summary of N comments" entry

**Concurrent Compaction and Sync**
- Compaction creates new JSONL entries; old entries remain until git gc
- Sync merges compacted and non-compacted versions: Non-compacted wins (more data)
- Race condition: Compacting while sync in progress → Retry sync after compact

#### Daemon Edge Cases

**Socket Permission and Cleanup**
- Socket path: `~/.eluent/daemon.sock`
- Permissions: 0600 (user only)
- Stale socket detection: If socket exists but daemon not running, delete and recreate
- Multiple daemon prevention: PID file at `~/.eluent/daemon.pid`

**Request Timeout**
- Default: 30 seconds for operations
- Long operations (sync): 5 minute timeout
- Timeout error: `TimeoutError` with operation context

**Daemon Crash Recovery**
- Daemon writes in-memory state to disk every 5 seconds
- On restart: Load from disk, replay any unconfirmed operations
- Client retry: If daemon unreachable, CLI falls back to direct file access

#### Miscellaneous Edge Cases

**Empty Repository**
- `el list` on empty repo: Return empty list, no error
- `el ready` on empty repo: Return empty list with hint message
- `el sync` on empty repo: Create initial commit with empty data.jsonl

**Very Long Titles/Descriptions**
- Title max: 500 characters (truncate with warning)
- Description max: 64KB (reject if larger)
- Comment max: 64KB per comment

**Unicode and Encoding**
- All text fields: UTF-8 encoded
- Invalid UTF-8: Reject at input with `EncodingError`
- Normalization: NFC form for consistent comparison

**Timezone Handling**
- All timestamps: UTC (ISO 8601 format with Z suffix)
- Display: Convert to local timezone for human output
- Input: Accept local times, convert to UTC for storage

### Manual Testing

```bash
# Initialize
cd /tmp/test-repo && git init && el init

# Create items
el create --title "Task 1" --type task
el create --title "Task 2" --type task --blocking el-xxxxx

# Check ready work with sort policies
el ready --sort=priority
el ready --sort=hybrid

# Ephemeral workflow
el create --ephemeral --title "Debug session"
el list --ephemeral
el update ID --persist

# Daemon flow
el daemon start
el list --json  # via daemon
el daemon stop

# Sync
git remote add origin <url>
el sync
```

---

## Implementation Order

1. **Foundation** - Models, Storage, basic CLI (init/create/list/show)
2. **Graph** - Dependencies, blocking, ready work
3. **Sync/Daemon** - Git sync, Unix socket daemon
4. **Formulas** - Templates and compaction
5. **Extensions** - Plugins and AI integration
6. **Polish** - Tests, types, documentation
