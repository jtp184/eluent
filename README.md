# 🧪 Eluent

A Ruby implementation of [Molecular Expression of Work](https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04#b03b) - a dependency-driven work orchestration and task tracking system for humans and AI agents.

## What is Eluent?

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

## Status

Eluent is in early development. See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) for the roadmap.

## Installation

Install the gem by executing:

```bash
gem install eluent
```

## Getting Started

### Basic Operations

```bash
el init                      # Initialize .eluent/ in current repo
el create --title "My task"  # Create a work item
el list                      # List open items
el list --all                # List all items including closed
el show ID                   # Show item details
el ready                     # Show ready-to-work items
```

### Item Lifecycle

```bash
el update ID --status in_progress   # Start working on item
el update ID --priority 1           # Set high priority
el update ID --assignee @me         # Assign to yourself
el close ID                         # Mark item as done
el reopen ID                        # Reopen a closed item
```

### Dependencies

```bash
el dep add A B               # A blocks B (A must complete first)
el dep add A B --type related       # Add informational link
el dep list ID               # Show dependencies for an item
el dep tree ID               # Visualize dependency tree
el dep check                 # Find issues in dependency graph
```

### Comments

```bash
el comment add ID "My note"  # Add a comment
el comment list ID           # List comments on item
```

### Discard and Restore

```bash
el discard ID                # Soft delete an item
el discard list              # List discarded items
el discard restore ID        # Restore a discarded item
el discard prune --days 30   # Permanently delete old discards
```

### Formulas (Templates)

```bash
el formula list              # List available formulas
el formula show ID           # Show formula details
el formula instantiate ID -V name=value  # Create items from template
```

### Sync and Daemon

```bash
el sync                      # Sync with git
el daemon start              # Start background sync daemon
el daemon stop               # Stop daemon
el daemon status             # Check daemon status
```

### Configuration

```bash
el config show               # Show current configuration
el config get key            # Get a config value
el config set key value      # Set a config value
```

## Reference

### Status Values

| Status | Description |
|--------|-------------|
| `open` | New or ready to work on |
| `in_progress` | Currently being worked on |
| `blocked` | Waiting on dependencies |
| `deferred` | Postponed until later |
| `closed` | Completed |
| `discard` | Soft-deleted |

### Issue Types

| Type | Description |
|------|-------------|
| `task` | Default work item |
| `feature` | New functionality |
| `bug` | Defect to fix |
| `artifact` | Non-actionable record |
| `epic` | Abstract container (cannot be closed directly) |
| `formula` | Template definition (abstract) |

### Dependency Types

**Blocking** (affects readiness):
- `blocks` - Source must complete before target can start (default)
- `parent_child` - Hierarchical containment
- `conditional_blocks` - Blocks under certain conditions
- `waits_for` - Target waits for source

**Informational** (no blocking effect):
- `related` - General relationship
- `duplicates` - Marks duplicate items
- `discovered_from` - Origin tracking
- `replies_to` - Response to another item

### Priority Levels

| Level | Meaning |
|-------|---------|
| 0 | Critical - highest priority |
| 1 | High |
| 2 | Medium (default) |
| 3 | Low |
| 4 | Minimal |
| 5 | None - lowest priority |

### Sort Policies for `el ready`

| Policy | Description |
|--------|-------------|
| `priority` | Sort by priority (lowest number first) |
| `oldest` | Sort by creation date (oldest first) |
| `hybrid` | Priority first, then age within same priority |

## Plugins

Eluent supports plugins from three sources:

- **Local**: `.eluent/plugins/*.rb` in your repository
- **Global**: `~/.eluent/plugins/*.rb` in your home directory
- **Gems**: Any installed gem named `eluent-*`

Plugins can add lifecycle hooks, custom commands, and new types. See [Plugin Development Guide](docs/PLUGIN_DEVELOPMENT.md) for details.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt.

To install this gem onto your local machine, run `bundle exec rake install`.

## Acknowledgments

Inspired by [beads](https://github.com/steveyegge/beads), which coined the MEOW through a git-backed issue tracker designed for AI agent workflows.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jtp184/eluent.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
