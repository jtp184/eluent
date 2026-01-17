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

```bash
el init                      # Initialize .eluent/ in current repo
el create --title "My task"  # Create a work item
el list                      # List items
el ready                     # Show ready-to-work items
el dep add A B               # Add dependency: A blocks on B
el sync                      # Sync with git
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt.

To install this gem onto your local machine, run `bundle exec rake install`.

## Acknowledgments

Inspired by [beads](https://github.com/steveyegge/beads), which coined the MEOW through a git-backed issue tracker designed for AI agent workflows.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/jtp184/eluent.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
