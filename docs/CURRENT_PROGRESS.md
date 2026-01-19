# Eluent Implementation Progress

**Last Updated**: 2026-01-18

This document tracks progress towards completing the implementation plan defined in `IMPLEMENTATION_PLAN.md`.

---

## Overview

| Phase | Status | Progress |
|-------|--------|----------|
| Phase 1: Foundation | Complete | 100% |
| Phase 2: Graph Operations | Complete | 100% |
| Phase 3: Sync and Daemon | Not Started | 0% |
| Phase 4: Formulas and Compaction | Not Started | 0% |
| Phase 5: Extensions and AI | Not Started | 0% |
| Phase 6: Polish | In Progress | 20% |

**Current State**: Production-ready for single-agent, single-repo workflows with full dependency graph support, ephemeral items, and 12 CLI commands.

---

## Phase 1: Foundation

Models, Storage, basic CLI (init/create/list/show/update/close/reopen/config)

### Core

- [x] `lib/eluent/version.rb` — Gem version constant

### Models

- [x] `lib/eluent/models/atom.rb` — Core entity with all fields (id, title, description, status, issue_type, priority, labels, assignee, parent_id, defer_until, close_reason, ephemeral, created_at, updated_at, metadata)
- [x] `lib/eluent/models/bond.rb` — Dependency relationship entity
- [x] `lib/eluent/models/comment.rb` — Append-only discussion with author tracking
- [x] `lib/eluent/models/status.rb` — 6 statuses: open, in_progress, blocked, deferred, closed, discard
- [x] `lib/eluent/models/issue_type.rb` — 6 types: feature, bug, task, artifact, epic (abstract), formula (abstract)
- [x] `lib/eluent/models/dependency_type.rb` — 8 types: 4 blocking (blocks, parent_child, conditional_blocks, waits_for), 4 informational (related, duplicates, discovered_from, replies_to)
- [x] `lib/eluent/models/mixins/extendable_collection.rb` — Plugin-extensible enumerations with dynamic predicate methods
- [x] `lib/eluent/models/mixins/validations.rb` — Shared validation logic

### Storage

- [x] `lib/eluent/storage/jsonl_repository.rb` — JSONL persistence with file locking, ephemeral support, and persist_atom method
- [x] `lib/eluent/storage/indexer.rb` — Dual-index: exact hash lookup + randomness prefix trie with source file tracking
- [x] `lib/eluent/storage/prefix_trie.rb` — Prefix matching for ID shortening
- [x] `lib/eluent/storage/paths.rb` — Path resolution for .eluent/ directory structure
- [x] `lib/eluent/storage/file_operations.rb` — File I/O with advisory locking and atomic writes
- [x] `lib/eluent/storage/config_loader.rb` — config.yaml loading with schema validation and defaults
- [x] `lib/eluent/storage/serializers/base.rb` — Base serializer with type dispatch
- [x] `lib/eluent/storage/serializers/atom_serializer.rb` — Atom JSON serialization
- [x] `lib/eluent/storage/serializers/bond_serializer.rb` — Bond JSON serialization
- [x] `lib/eluent/storage/serializers/comment_serializer.rb` — Comment JSON serialization

### Registry

- [x] `lib/eluent/registry/id_generator.rb` — ULID generation (Crockford Base32, 26 chars)
- [x] `lib/eluent/registry/id_resolver.rb` — Shortening by randomness portion (last 16 chars), normalization (I,L→1, O→0), minimum 4-char prefix, AmbiguousIdError with candidates

### CLI Foundation

- [x] `lib/eluent/cli/application.rb` — Main CLI entry point with COMMANDS registry and error code mapping
- [x] `lib/eluent/cli/formatting.rb` — Output formatting helpers (tables, colors, boxes, trees)
- [x] `exe/el` — CLI executable

### CLI Commands (Phase 1)

- [x] `lib/eluent/cli/commands/init.rb` — Initialize .eluent/ with config.yaml and .gitignore
- [x] `lib/eluent/cli/commands/create.rb` — Create atoms with --ephemeral flag support
- [x] `lib/eluent/cli/commands/list.rb` — List with filters (status, type, assignee, labels, --include-discarded, --ephemeral)
- [x] `lib/eluent/cli/commands/show.rb` — Show item details with full/short ID display
- [x] `lib/eluent/cli/commands/update.rb` — Update fields including --persist for ephemeral→persistent transition
- [x] `lib/eluent/cli/commands/close.rb` — Close with --reason
- [x] `lib/eluent/cli/commands/reopen.rb` — Reopen closed items
- [x] `lib/eluent/cli/commands/config.rb` — Configuration management (show/set/get)

### Project Setup

- [x] `eluent.gemspec` — Gem specification with TTY suite, pastel, httpx
- [x] `Gemfile` — Development dependencies (rspec, fakefs, timecop, webmock, rubocop)

---

## Phase 2: Graph Operations

Dependencies, blocking, ready work

### Graph

- [x] `lib/eluent/graph/dependency_graph.rb` — DAG with path_exists?, all_descendants, all_ancestors, direct_blockers, direct_dependents, blocking_only traversal
- [x] `lib/eluent/graph/cycle_detector.rb` — Pre-creation validation with cycle path return, self-reference prevention
- [x] `lib/eluent/graph/blocking_resolver.rb` — Transitive blocking for all 4 types with caching:
  - `blocks`: Source must be closed
  - `parent_child`: Parent chain must be closed (cascades up)
  - `conditional_blocks`: Only blocks if source failed (FAILURE_PATTERN = `/^(fail|error|abort)/i`)
  - `waits_for`: Source AND all descendants must be closed

### Lifecycle

- [x] `lib/eluent/lifecycle/transition.rb` — Status state machine with configurable allowed transitions
- [x] `lib/eluent/lifecycle/readiness_calculator.rb` — Ready work query with:
  - Sort policies: priority (default), oldest, hybrid (48h threshold)
  - Abstract type exclusion (epic, formula)
  - Filtering by type, assignee, labels, priority
  - Deferred item handling (lazy evaluation via defer_until)

### CLI Commands (Phase 2)

- [x] `lib/eluent/cli/commands/ready.rb` — Show ready items with --sort, --type, --assignee, --label, --priority filters
- [x] `lib/eluent/cli/commands/dep.rb` — Dependency management: add (with cycle detection), remove, list, tree, check
- [x] `lib/eluent/cli/commands/comment.rb` — Comment add/list with author tracking
- [x] `lib/eluent/cli/commands/discard.rb` — Soft deletion: discard, list, restore, prune (--all, --ephemeral)

### Integration

- [x] `lib/eluent/storage/jsonl_repository.rb` — delete_atom method for permanent removal
- [x] `lib/eluent/cli/application.rb` — 12 commands registered, exit codes (0-5)
- [x] `lib/eluent.rb` — Requires for graph and lifecycle modules

### Specs

- [x] `spec/eluent/graph/dependency_graph_spec.rb` — 24 examples covering DAG operations
- [x] `spec/eluent/graph/cycle_detector_spec.rb` — 12 examples covering cycle detection
- [x] `spec/eluent/graph/blocking_resolver_spec.rb` — 24 examples covering all 4 blocking types
- [x] `spec/eluent/lifecycle/transition_spec.rb` — 19 examples covering state machine
- [x] `spec/eluent/lifecycle/readiness_calculator_spec.rb` — 18 examples covering sort policies and filters

---

## Phase 3: Sync and Daemon

Git sync, Unix socket daemon

### Sync

- [ ] `lib/eluent/sync/git_adapter.rb` — Git operations wrapper
- [ ] `lib/eluent/sync/merge_engine.rb` — 3-way merge (LWW for scalars, union for sets, append+dedup for comments)
- [ ] `lib/eluent/sync/pull_first_orchestrator.rb` — Pull-first sync flow
- [ ] `lib/eluent/sync/sync_state.rb` — .sync-state file handling
- [ ] `lib/eluent/sync/conflict_resolver.rb` — Resurrection rule (edit wins over delete)

### Registry

- [ ] `lib/eluent/registry/repo_registry.rb` — Cross-repo registry (~/.eluent/repos.jsonl)
- [ ] `lib/eluent/registry/repo_context.rb` — Repository context management

### Daemon

- [ ] `lib/eluent/daemon/server.rb` — Unix socket server with PID file
- [ ] `lib/eluent/daemon/protocol.rb` — Length-prefixed JSON protocol
- [ ] `lib/eluent/daemon/command_router.rb` — Route to handlers

### CLI Commands (Phase 3)

- [ ] `lib/eluent/cli/commands/sync.rb` — Sync command (--pull-only, --push-only)
- [ ] `lib/eluent/cli/commands/daemon.rb` — Daemon management (start/stop/status)

---

## Phase 4: Formulas and Compaction

Templates and compaction

### Models

- [ ] `lib/eluent/models/formula.rb` — Template definition

### Formulas

- [ ] `lib/eluent/formulas/parser.rb` — YAML formula parsing
- [ ] `lib/eluent/formulas/variable_resolver.rb` — Variable substitution ({{var}} syntax)
- [ ] `lib/eluent/formulas/instantiator.rb` — Create items from template
- [ ] `lib/eluent/formulas/distiller.rb` — Extract template from work
- [ ] `lib/eluent/formulas/composer.rb` — Combine formulas (sequential/parallel/conditional)

### Compaction

- [ ] `lib/eluent/compaction/compactor.rb` — Tier 1/2 compaction
- [ ] `lib/eluent/compaction/summarizer.rb` — Summarize content for compaction
- [ ] `lib/eluent/compaction/restorer.rb` — Restore original content from git history

### CLI Commands (Phase 4)

- [ ] `lib/eluent/cli/commands/formula.rb` — Formula commands (list/show/instantiate/distill/compose/attach)

---

## Phase 5: Extensions and AI

Plugins and AI integration

### Plugins

- [ ] `lib/eluent/plugins/plugin_manager.rb` — Discovery and loading
- [ ] `lib/eluent/plugins/plugin_context.rb` — Plugin DSL sandbox
- [ ] `lib/eluent/plugins/hooks.rb` — Hook registration and invocation
- [ ] `lib/eluent/plugins/gem_loader.rb` — Load eluent-* gems

### Agents

- [ ] `lib/eluent/agents/agent_executor.rb` — Abstract AI interface
- [ ] `lib/eluent/agents/execution_loop.rb` — Standard agent work loop
- [ ] `lib/eluent/agents/implementations/claude_executor.rb` — Claude integration
- [ ] `lib/eluent/agents/implementations/openai_executor.rb` — OpenAI integration

### CLI Commands (Phase 5)

- [ ] `lib/eluent/cli/commands/plugin.rb` — Plugin management (list/install/enable/disable/hook)

---

## Phase 6: Polish

Tests, types, documentation

### Testing

- [x] Unit tests for graph operations (97 examples)
- [ ] Unit tests for all models
- [ ] Unit tests for storage layer
- [ ] Integration tests for CLI commands
- [ ] Daemon concurrent access tests
- [ ] Sync 3-way merge scenario tests

### Type Checking

- [ ] RBS type signatures for public APIs
- [ ] Steep configuration and type checking

### Documentation

- [ ] README.md with usage examples
- [ ] CLI help text for all commands
- [ ] Plugin development guide

---

## Implementation Notes

### Ephemeral Items
- Stored in `.eluent/ephemeral.jsonl` (git-ignored)
- Created with `el create --ephemeral`
- Converted to persistent with `el update ID --persist`
- Pruned with `el discard prune --ephemeral`
- Auto-cleanup timer deferred to daemon implementation (Phase 3)

### ID System
- ULID format: 26 chars (10 timestamp + 16 randomness)
- Shortening matches against randomness portion only
- Minimum 4-char prefix required for lookup
- Confusable character normalization: I,L→1, O→0

### Blocking Semantics
- All 4 blocking types implemented with transitive resolution
- BlockingResolver caches results with manual invalidation
- Ready work excludes abstract types (epic, formula) by default
