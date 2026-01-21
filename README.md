# Eluent

A Ruby implementation of [Molecular Expression of Work](https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04#b03b) (MEOW) - a dependency-driven work orchestration and task tracking system for humans and AI agents.

## Overview

Eluent is a CLI tool (`el`) and prescribed workflow for managing work items as a directed acyclic graph where dependencies control execution order. Agents (human or AI) progress by claiming and completing whatever work is "ready" - items with no blockers. Tasks are stored alongside code in git, enabling decentralized collaboration, intelligent conflict handling, and offline work.

**Core concepts:**

- **Atoms** - The fundamental work unit (task, bug, feature, etc.)
- **Bonds** - Dependency relationships between atoms (`blocks`, `waits-for`, `conditional-blocks`, etc.)
- **Molecules** - Container atoms that group related work
- **Formulas** - Reusable templates for creating work patterns
- **Phases** - Work can be persistent (synced to git) or ephemeral (local-only)

**Design principles:**

- Work is persistent memory, not transient state
- Dependencies encode execution constraints, not suggestions
- Parallelism is the default; sequence requires explicit declaration
- Agents don't need plans - the graph is the plan

## Installation

Install the gem:

```bash
gem install eluent
```

Or add to your Gemfile:

```ruby
gem 'eluent'
```

## Quick Start

```bash
# Initialize in your repository
el init

# Create some work items
el create --title "Set up authentication"
el create --title "Add login form" --type feature
el create --title "Fix password validation" --type bug --priority 1

# Add a dependency (login form waits for auth)
el dep add AUTH_ID LOGIN_ID

# See what's ready to work on
el ready

# Start working on an item
el update AUTH_ID --status in_progress

# Complete it
el close AUTH_ID
```

## Core Concepts

### Atoms

Atoms are the fundamental unit of work. Each atom has:

| Attribute | Description |
|-----------|-------------|
| `id` | Unique identifier (UUID-based, supports short prefixes) |
| `title` | Brief description of the work |
| `description` | Detailed explanation (optional) |
| `status` | Current state: `open`, `in_progress`, `blocked`, `review`, `testing`, `deferred`, `closed`, `wont_do`, `discard` |
| `issue_type` | Category: `task`, `feature`, `bug`, `artifact`, `discovery`, `epic`, `formula` |
| `priority` | 0 (critical) to 5 (none), default 2 |
| `assignee` | Who's working on it |
| `labels` | Arbitrary tags for classification |
| `parent_id` | For hierarchical containment (molecules) |
| `defer_until` | Timestamp for scheduled activation |

### Bonds

Bonds are dependencies between atoms. They come in two categories:

**Blocking bonds** (affect readiness):
| Type | Description |
|------|-------------|
| `blocks` | Source must complete before target can start (default) |
| `parent_child` | Hierarchical containment relationship |
| `conditional_blocks` | Blocks under certain conditions |
| `waits_for` | Target waits for source |

**Informational bonds** (no blocking effect):
| Type | Description |
|------|-------------|
| `related` | General relationship |
| `duplicates` | Marks duplicate items |
| `discovered_from` | Origin tracking |
| `replies_to` | Response to another item |

### Status Lifecycle

```
open → in_progress → review → testing → closed
  ↓         ↓           ↓         ↓        ↑
  └───────blocked───────┴─────────┴────────┘
  ↓
deferred (with defer_until)

Terminal states:
  wont_do (decided not to do)
  discard (soft delete)
```

### Issue Types

| Type | Description |
|------|-------------|
| `task` | Default work item |
| `feature` | New functionality |
| `bug` | Defect to fix |
| `artifact` | Deliverable document or non-code output |
| `discovery` | Research or investigation that produces related tickets |
| `epic` | Abstract container (cannot be closed directly) |
| `formula` | Template definition (abstract) |

### Priority Levels

| Level | Meaning |
|-------|---------|
| 0 | Critical - highest priority |
| 1 | High |
| 2 | Medium (default) |
| 3 | Low |
| 4 | Minimal |
| 5 | None - lowest priority |

## CLI Reference

### Global Options

All commands support:
- `-h, --help` - Print usage
- `--robot` - Machine-readable JSON output
- `-v, --verbose` - Verbose output
- `--debug` - Debug output (shows backtraces)

### Initialization

```bash
el init                      # Initialize .eluent/ in current repo
```

### Creating Items

```bash
el create --title "My task"                    # Basic creation
el create -t "Feature" --type feature          # Specify type
el create -t "Critical bug" --priority 0       # High priority
el create -t "UI work" --label ui --label v2   # With labels
el create -t "Subtask" --parent PARENT_ID      # As child of molecule
el create -t "Local only" -e                   # Ephemeral (not synced)
el create -t "Blocked task" -b BLOCKER_ID      # Create with dependency
el create -i                                   # Interactive mode (TTY)
```

### Listing and Viewing

```bash
el list                      # List open items
el list --all                # Include closed items
el show ID                   # Show item details (supports short IDs)
el ready                     # Show ready-to-work items
el ready --sort priority     # Sort by priority (default)
el ready --sort oldest       # Sort by creation date
el ready --sort hybrid       # Priority first, then age
el ready --type bug          # Filter by type
el ready --exclude-type epic # Exclude types
el ready --assignee @me      # Filter by assignee
el ready --label urgent      # Filter by label
el ready --priority 1        # Filter by priority
el ready --include-abstract  # Include epics/formulas
```

### Updating Items

```bash
el update ID --status in_progress   # Change status
el update ID --priority 1           # Change priority
el update ID --assignee alice       # Assign to user
el update ID --label bug --label ui # Set labels
el update ID --description "..."    # Update description
el close ID                         # Mark as done
el reopen ID                        # Reopen closed item
```

### Dependencies

```bash
el dep add A B                      # A blocks B (default)
el dep add A B --type related       # Informational link
el dep add A B --type waits_for     # B waits for A
el dep remove A B                   # Remove dependency
el dep list ID                      # List dependencies for item
el dep tree ID                      # Visualize dependency tree
el dep check                        # Find graph issues (cycles, etc.)
```

### Comments

```bash
el comment add ID "Progress update"  # Add comment
el comment list ID                   # List comments
```

### Discard and Restore

```bash
el discard ID                # Soft delete
el discard list              # List discarded items
el discard restore ID        # Restore item
el discard prune --days 30   # Permanently delete old items
```

### Claiming Items (Multi-Agent)

```bash
el claim ID                  # Claim for exclusive work
el claim ID --agent-id bot1  # Claim as specific agent
el claim ID --offline        # Local-only claim (sync later)
el claim ID --force          # Steal from another agent
```

**Exit codes:**
- 0: Success
- 1: Conflict (already claimed)
- 2: Retries exhausted
- 3: Ledger unconfigured
- 4: Atom not found
- 5: Terminal state (closed/discarded)

### Formulas (Templates)

```bash
el formula list                           # List available formulas
el formula show ID                        # Show formula details
el formula instantiate ID -V name=value   # Create from template
el formula distill ROOT_ID --id new-id    # Extract formula from work
el formula compose A B --type sequential  # Combine formulas
el formula attach ID TARGET               # Attach to existing item
```

### Sync and Daemon

```bash
el sync                      # Sync with git remote
el sync --pull-only          # Only pull changes
el sync --push-only          # Only push changes
el sync --dry-run            # Preview sync
el sync --setup-ledger       # Initialize ledger branch
el sync --ledger-only        # Sync only ledger
el sync --reconcile          # Reconcile offline claims
el sync --status             # Show sync status

el daemon start              # Start background sync
el daemon stop               # Stop daemon
el daemon status             # Check daemon status
```

### Compaction

```bash
el compact                   # Compact old closed items
el compact --preview         # Preview changes
el compact --tier 1          # Light compaction (30+ days)
el compact --tier 2          # Aggressive compaction (90+ days)
```

### Configuration

```bash
el config show               # Show all config
el config get key            # Get value (dot notation: defaults.priority)
el config set key value      # Set value
el config set key value --global  # Set in ~/.eluent/config.yaml
el config set key value --local   # Set in .eluent/config.yaml
```

### Plugins

```bash
el plugin list               # List loaded plugins
el plugin show NAME          # Show plugin details
```

## Configuration

Eluent uses two configuration files (YAML format):

- **Global**: `~/.eluent/config.yaml` - User-wide defaults
- **Local**: `.eluent/config.yaml` - Repository-specific overrides

### Example Configuration

```yaml
# Default values for new items
defaults:
  priority: 2
  issue_type: task

# Sync settings
sync:
  auto_push: true
  git_timeout: 30

# Daemon settings
daemon:
  interval: 60

# Agent settings
agents:
  claim_timeout_hours: 24
  auto_release_stale: true
```

### Configuration Keys

| Key | Description |
|-----|-------------|
| `defaults.priority` | Default priority for new items |
| `defaults.issue_type` | Default type for new items |
| `sync.auto_push` | Auto-push after local changes |
| `sync.git_timeout` | Git operation timeout (seconds) |
| `daemon.interval` | Sync interval (seconds) |
| `agents.claim_timeout_hours` | Auto-release claims after this time |
| `agents.auto_release_stale` | Enable automatic stale claim release |

## Formulas

Formulas are templates for creating consistent work patterns. Define them in `.eluent/formulas/`.

### Example Formula

```yaml
# .eluent/formulas/feature-development.yaml
id: feature-development
title: Standard Feature Development
version: 1.0.0
retention: permanent

variables:
  - name: feature_name
    required: true
    description: Name of the feature
  - name: priority
    default: 2
    enum: [0, 1, 2, 3, 4, 5]

steps:
  - id: design
    title: "Design {{feature_name}}"
    type: task
    priority: "{{priority}}"

  - id: implement
    title: "Implement {{feature_name}}"
    type: feature
    depends_on: [design]

  - id: test
    title: "Test {{feature_name}}"
    type: task
    depends_on: [implement]

  - id: review
    title: "Code review {{feature_name}}"
    type: task
    depends_on: [implement]

  - id: deploy
    title: "Deploy {{feature_name}}"
    type: task
    depends_on: [test, review]
```

### Using Formulas

```bash
# Instantiate the template
el formula instantiate feature-development -V feature_name="User Auth"

# This creates 5 atoms with proper dependencies:
# design → implement → test  ↘
#                     review → deploy
```

### Formula Operations

- **Instantiate**: Create atoms from template
- **Distill**: Extract a formula from completed work
- **Compose**: Combine multiple formulas (sequential, parallel, conditional)
- **Attach**: Add formula steps to an existing atom

## Multi-Agent Coordination

Eluent uses a ledger branch system for atomic coordination between multiple agents.

### Architecture

```
Remote: eluent-sync (orphan branch) → .eluent/ only
Local: ~/.eluent/<repo>/.sync-worktree/ → git worktree checkout
State: ~/.eluent/<repo>/.ledger-sync-state → JSON metadata
```

### Setting Up

```bash
# Initialize the ledger branch
el sync --setup-ledger

# Start the daemon for background sync
el daemon start
```

### Claiming Work

When multiple agents work on the same repository:

1. Agent claims an item: `el claim ID --agent-id agent1`
2. Claim is pushed to ledger branch atomically
3. Other agents see the claim when they sync
4. If conflict, retry with exponential backoff
5. Agent completes work and closes item
6. Claim is released

### Offline Work

```bash
# Work offline
el claim ID --offline

# Later, reconcile claims
el sync --reconcile
```

### Stale Claim Management

Configure automatic release of abandoned claims:

```yaml
# config.yaml
agents:
  claim_timeout_hours: 24
  auto_release_stale: true
```

## Compaction

Over time, closed items accumulate. Compaction reduces storage while preserving history.

### Tiers

| Tier | Age | Effect |
|------|-----|--------|
| 1 | 30+ days | Light: truncate descriptions, summarize comments |
| 2 | 90+ days | Aggressive: one-liner descriptions, remove comments |

### Usage

```bash
# Preview what would be compacted
el compact --preview

# Apply light compaction
el compact --tier 1

# Apply aggressive compaction
el compact --tier 2
```

Original content is preserved in git history and can be restored.

## Plugins

Eluent supports plugins from three sources:

1. **Local**: `.eluent/plugins/*.rb` - Repository-specific
2. **Global**: `~/.eluent/plugins/*.rb` - User-wide
3. **Gems**: Any gem named `eluent-*` - Auto-discovered

### Plugin Example

```ruby
# .eluent/plugins/my_plugin.rb
Eluent::Plugins.register(:my_plugin, path: __FILE__) do
  # Add lifecycle hooks
  before_create(priority: 50) do |context|
    # Validate or modify before creation
    if context.item.title.empty?
      context.halt!("Title cannot be empty")
    end
  end

  after_close(priority: 100) do |context|
    # Notify, log, or trigger actions
    puts "Closed: #{context.item.title}"
  end

  on_status_change do |context|
    old_status, new_status = context.changes[:status]
    puts "Status changed from #{old_status} to #{new_status}"
  end

  # Add custom commands
  add_command :my_command do |args, repo|
    # Command implementation
    puts "Custom command executed"
  end

  # Extend types
  extend_type :status, :review, blocking: false
end
```

### Available Hooks

| Hook | Phase | Can Abort? |
|------|-------|------------|
| `before_create` | Before item created | Yes |
| `after_create` | After item created | No |
| `before_update` | Before item updated | Yes |
| `after_update` | After item updated | No |
| `before_close` | Before item closed | Yes |
| `after_close` | After item closed | No |
| `on_status_change` | When status changes | No |
| `on_sync` | During sync operations | No |

Hooks execute in priority order (lower numbers first). Use `context.halt!(reason)` in `before_*` hooks to abort the operation.

## AI Agent Integration

Eluent provides a framework for AI agents to autonomously work on items.

### Supported Providers

- **Claude** (Anthropic)
- **OpenAI**

### Configuration

Set API keys as environment variables:

```bash
export ANTHROPIC_API_KEY="sk-..."
export OPENAI_API_KEY="sk-..."
```

### Agent Tools

Agents have access to these tools:

| Tool | Description |
|------|-------------|
| `list_items` | List work items with filtering |
| `show_item` | Display item details |
| `create_item` | Create new work item |
| `update_item` | Modify item |
| `close_item` | Mark item complete |
| `add_dependency` | Create dependency |
| `claim_item` | Reserve item for work |
| `add_comment` | Annotate item |

### Agent Workflow

1. Agent calls `list_items` or `ready` to find work
2. Agent claims item with `claim_item`
3. Agent performs work (code changes, etc.)
4. Agent closes item with `close_item` and reason
5. Agent can create follow-up items if needed

## Environment Variables

| Variable | Description |
|----------|-------------|
| `USER` | Default author for comments |
| `EL_DEBUG` | Enable debug output |
| `ELUENT_DEBUG` | Enable debug output for agent JSON parsing |
| `XDG_DATA_HOME` | Override for global data directory |
| `ANTHROPIC_API_KEY` | Claude API authentication |
| `OPENAI_API_KEY` | OpenAI API authentication |

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 1 | Generic error |
| 2 | Validation error (invalid input) |
| 3 | Not found (atom, formula, repo) |
| 4 | Already exists / ambiguous ID / cycle |
| 5 | Git error |
| 6 | Daemon error |
| 7 | Connection timeout |
| 8 | Compaction error |
| 9 | Plugin error |
| 10 | Config error (auth, rate limit) |

## File Structure

```
.eluent/
├── config.yaml          # Local configuration
├── data.jsonl           # Atoms, bonds, comments (JSON Lines)
├── formulas/            # Formula definitions
│   └── *.yaml
└── plugins/             # Local plugins
    └── *.rb

~/.eluent/
├── config.yaml          # Global configuration
├── plugins/             # Global plugins
│   └── *.rb
├── daemon.sock          # Daemon socket
├── daemon.pid           # Daemon PID file
├── daemon.log           # Daemon log
└── <repo-name>/         # Per-repository sync data
    ├── .sync-worktree/  # Git worktree for ledger
    ├── .ledger-sync-state  # Sync metadata
    └── .ledger.lock     # Cross-process lock
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt.

To install this gem onto your local machine, run `bundle exec rake install`.

### Running Tests

```bash
rake spec              # Run all tests
rake spec SPEC=spec/path/to_spec.rb  # Run specific test
```

### Code Style

The project uses RuboCop for code style enforcement:

```bash
rubocop                # Check style
rubocop -a             # Auto-fix issues
```

## Troubleshooting

### "Repository not initialized"

Run `el init` in your git repository.

### "Ambiguous ID"

Your short ID matches multiple atoms. Use more characters or the full ID. The error message lists matching candidates.

### "Cycle detected"

The dependency you're trying to add would create a circular dependency. Use `el dep check` to inspect the graph.

### Daemon won't start

Check if it's already running with `el daemon status`. Check `~/.eluent/daemon.log` for errors.

### Sync conflicts

Use `el sync --reconcile` to reconcile offline claims. For persistent issues, use `el sync --force-resync`.

### Claim failures

- Exit code 1: Another agent has the claim. Wait or use `--force`.
- Exit code 2: Network issues. Check connectivity and try again.
- Exit code 3: Run `el sync --setup-ledger` to initialize.

## Acknowledgments

Inspired by [beads](https://github.com/steveyegge/beads), which coined MEOW through a git-backed issue tracker designed for AI agent workflows.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jtp184/eluent.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
