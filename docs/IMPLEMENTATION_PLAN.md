# Eluent Implementation Plan

**CLI Command**: `el`
**Ruby Version**: 4.0.1
**Storage**: JSONL files in `.eluent/` per repo, committed to git
**Cross-repo**: Shared registry at `~/.eluent/repos.jsonl`, supports inter-repo dependencies

---

## Architecture Overview

```
Eluent
├── Models         # Atom, Bond, Molecule, Formula
├── Lifecycle      # Status, Transition, ReadinessCalculator
├── Graph          # DependencyGraph, CycleDetector, BlockingResolver
├── Storage        # JsonlRepository, Indexer, Serializers
├── Sync           # GitAdapter, MergeEngine, ConflictResolver
├── Registry       # RepoRegistry, RepoContext, IdGenerator
├── Daemon         # Server (Unix sockets), Protocol, CommandRouter
├── CLI            # Application, Commands, OutputFormatter, Middleware
├── Formulas       # Parser, VariableResolver, Instantiator, Distiller
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
├── formulas/           # Formula definitions (YAML)
├── plugins/            # Local plugin scripts (.rb)
└── .sync-state         # Last sync metadata
```

**ID Format**: `{repo_name}-{short_hash}` (e.g., `eluent-a7b3c`)

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
el ready [filters]               # Show ready-to-work items
el dep add|remove|list|tree|check  # Dependency management
el comment add|list              # Comment management
el formula list|show|instantiate|distill|compose  # Templates
el sync [--pull-only|--push-only]  # Git-based sync
el swarm start|stop|status       # Daemon management (explicit start)
el config [local|global] show|set|get # Configuration
el plugin [name] list|install|enable|disable|hook # Plugin management
```

**Interactive Mode**: By base, commands with missing data (necessary fields not provided as arguments, etc. ) launches TTY prompt for guided input.
**Structured Output Mode**: `--robot` (universal modifier) emits structured JSON output for any command and does NOT run interactively or use rich formatting.

---

## Key Files to Create

### Phase 1: Foundation
| File | Purpose |
|------|---------|
| `lib/eluent/models/atom.rb` | Core Atom entity with all fields |
| `lib/eluent/models/bond.rb` | Bond entity with blocking types |
| `lib/eluent/models/comment.rb` | Append-only discussion |
| `lib/eluent/storage/jsonl_repository.rb` | JSONL persistence with locking |
| `lib/eluent/registry/id_generator.rb` | `{repo}-{hash}` ID generation |
| `lib/eluent/cli/application.rb` | Main CLI entry point |
| `lib/eluent/cli/commands/init.rb` | Initialize .eluent/ |
| `lib/eluent/cli/commands/create.rb` | Create work items |
| `lib/eluent/cli/commands/list.rb` | List with filters |
| `lib/eluent/cli/commands/show.rb` | Show item details |
| `exe/el` | CLI executable |

### Phase 2: Graph Operations
| File | Purpose |
|------|---------|
| `lib/eluent/graph/dependency_graph.rb` | DAG structure |
| `lib/eluent/graph/cycle_detector.rb` | Prevent cycles |
| `lib/eluent/graph/blocking_resolver.rb` | Transitive blocking |
| `lib/eluent/lifecycle/status.rb` | Status enum |
| `lib/eluent/lifecycle/transition.rb` | State machine |
| `lib/eluent/lifecycle/readiness_calculator.rb` | Ready work query |
| `lib/eluent/cli/commands/ready.rb` | Show ready items |
| `lib/eluent/cli/commands/dep.rb` | Dependency management |

### Phase 3: Sync and Daemon
| File | Purpose |
|------|---------|
| `lib/eluent/sync/git_adapter.rb` | Git operations wrapper |
| `lib/eluent/sync/merge_engine.rb` | 3-way merge |
| `lib/eluent/sync/pull_first_orchestrator.rb` | Pull-first sync flow |
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
| `lib/eluent/formulas/instantiator.rb` | Create items from template |
| `lib/eluent/formulas/distiller.rb` | Extract template from work |
| `lib/eluent/compaction/compactor.rb` | Tier 1/2 compaction |
| `lib/eluent/cli/commands/formula.rb` | Formula commands |

### Phase 5: Extensions and AI
| File | Purpose |
|------|---------|
| `lib/eluent/plugins/plugin_manager.rb` | Discovery and loading |
| `lib/eluent/plugins/plugin_context.rb` | Plugin DSL sandbox |
| `lib/eluent/agents/agent_executor.rb` | Abstract AI interface |
| `lib/eluent/agents/implementations/claude_executor.rb` | Claude integration |
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

Length-prefixed JSON over Unix sockets:
- **Request**: `{ "cmd": "list", "args": {...}, "id": "req-123" }`
- **Response**: `{ "id": "req-123", "status": "ok", "data": {...} }`

Socket path: `~/.eluent/daemon.sock`

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

## Extension System

**Plugin sources** (in order):
1. `.eluent/plugins/*.rb` (project local)
2. `~/.eluent/plugins/*.rb` (user global)
3. `eluent-*` gems (installed)

**Plugin DSL**:
```ruby
Eluent::Plugins.register "my_plugin" do
  before_create { |ctx| ... }
  after_close { |ctx| ... }
  command "mycommand", description: "..." do |ctx| ... end
  register_issue_type :custom_type
  register_dependency_type :custom_dep, blocking: false
end
```

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
2. Claim item (set in_progress + assignee)
3. Execute via AI
4. Close with reason (or handle failure)
5. Create any needed follow-up items
6. Sync to git

---

## Verification Plan

1. **Unit tests**: RSpec for all models, storage, graph operations
2. **Integration tests**: CLI commands with temp directories
3. **Daemon tests**: Socket communication, concurrent access
4. **Sync tests**: 3-way merge scenarios with mock git
5. **Manual testing**:
   ```bash
   # Initialize
   cd /tmp/test-repo && git init && el init

   # Create items
   el create --title "Task 1" --type task
   el create --title "Task 2" --type task --blocking el-xxxxx

   # Check ready work
   el ready

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
