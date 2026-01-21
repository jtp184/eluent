# Molecular Expression of Work (MEOW)

A platform-agnostic specification for dependency-driven work orchestration.

---

## Overview

MEOW is a model for organizing, tracking, and executing work across agents (human or AI) over arbitrary timescales. Work items form a directed acyclic graph (DAG) where dependencies control execution order, and agents progress by claiming and completing whatever work is "ready."

**Core Philosophy:**
- Work is persistent memory, not transient state
- Dependencies encode execution constraints, not suggestions
- Parallelism is the default; sequence requires explicit declaration
- Agents don't need plans—the graph is the plan

---

## 1. Core Entities

### 1.1 Work Item (Atom)

The fundamental unit of trackable work.

**Required Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Globally unique identifier (collision-resistant) |
| `title` | string | Short description of work (max ~500 chars) |
| `status` | enum | Current state (see §2 Lifecycle) |
| `created_at` | timestamp | When created |
| `updated_at` | timestamp | Last modification time |

**Standard Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `description` | text | Detailed explanation |
| `issue_type` | enum | Categorization (see below) |
| `priority` | integer | Urgency (0=critical, 4=backlog) |
| `labels` | set[string] | Arbitrary tags for filtering |
| `assignee` | string | Responsible entity |
| `creator` | string | Who created the item |
| `parent_id` | string? | Parent item for hierarchy |

**Optional Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `acceptance_criteria` | text | Definition of done |
| `design` | text | Implementation approach |
| `notes` | text | Additional context |
| `defer_until` | timestamp? | Hidden from ready work until this time |
| `due_at` | timestamp? | Target completion date |
| `closed_at` | timestamp? | When work completed |
| `close_reason` | string? | Why/how work ended |

**Issue Types (Extensible):**
- **Work**: `task`, `bug`, `feature`, `chore`
- **Organizational**: `epic`, `molecule`
- **Workflow**: `gate`, `event`, `slot`

Implementations MAY define additional types. Types with the same name SHOULD have the same semantics across implementations.

### 1.2 Dependency (Bond)

A directed relationship between two work items.

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `source_id` | string | The dependent item |
| `target_id` | string | The item depended upon |
| `dependency_type` | enum | Relationship semantics |
| `created_at` | timestamp | When established |
| `metadata` | map? | Type-specific data |

**Dependency Types:**

*Blocking (affect work readiness):*
| Type | Semantics |
|------|-----------|
| `blocks` | Source cannot start until target closes |
| `parent-child` | Source belongs to target; inherits blocking |
| `conditional-blocks` | Source runs only if target fails |
| `waits-for` | Source waits for target's completion (with metadata) |

*Non-Blocking (informational):*
| Type | Semantics |
|------|-----------|
| `related` | Loosely connected work |
| `duplicates` | Source duplicates target |
| `discovered-from` | Source found while working on target |
| `replies-to` | Source is a response to target |

Implementations MUST support blocking types. Non-blocking types are OPTIONAL but RECOMMENDED.

### 1.3 Comment

Append-only discussion on a work item.

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier |
| `issue_id` | string | Parent work item |
| `author` | string | Who wrote it |
| `content` | text | The message |
| `created_at` | timestamp | When written |

### 1.4 Hierarchy (Molecule/Epic)

Work items with `parent_id` set form a tree structure:

```
root (epic/molecule)
├── child-a
│   ├── grandchild-1
│   └── grandchild-2
└── child-b
```

**Rules:**
- An item's parent MUST exist and MUST NOT create a cycle
- Children of the same parent are parallel by default (no implicit dependencies)
- Closing a parent does NOT automatically close children
- A blocked parent blocks all descendants

---

## 2. Lifecycle States

### 2.1 Status Values

| Status | Description | Can Transition To |
|--------|-------------|-------------------|
| `open` | Available for work | `in_progress`, `blocked`, `deferred`, `closed` |
| `in_progress` | Actively being worked | `open`, `blocked`, `deferred`, `closed` |
| `blocked` | Waiting on dependencies | `open`, `in_progress`, `deferred`, `closed` |
| `deferred` | Deliberately postponed | `open`, `in_progress`, `blocked`, `closed` |
| `closed` | Completed or cancelled | `open` (reopen) |
| `discard` | Soft-deleted | (terminal, may be pruned) |

### 2.2 State Diagram

```
                    ┌──────────────┐
                    │    open      │◄────────────┐
                    └──────┬───────┘             │
                           │                     │ reopen
            ┌──────────────┼──────────────┐      │
            ▼              ▼              ▼      │
    ┌───────────┐   ┌───────────┐   ┌─────┴─────┐
    │in_progress│   │  blocked  │   │  deferred │
    └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
          │               │               │
          └───────────────┼───────────────┘
                          ▼
                    ┌───────────┐
                    │  closed   │
                    └─────┬─────┘
                          │ delete
                          ▼
                    ┌───────────┐
                    │ discard   │
                    └───────────┘
```

### 2.3 Automatic Transitions

The following transitions MAY happen automatically:

1. **Blocking**: When a dependency is added that blocks an `open` item, status MAY change to `blocked`
2. **Unblocking**: When the last blocker closes, status MAY change from `blocked` to `open`
3. **Deferred expiry**: When `defer_until` passes, item becomes visible in ready work again

Implementations MAY keep `blocked` as a computed property rather than explicit status.

---

## 3. Ready Work Model

The core execution primitive: "What can I work on now?"

### 3.1 Definition

A work item is **ready** if ALL of the following are true:
1. Status is `open` OR `in_progress`
2. No blocking dependencies to unclosed items
3. Not soft-deleted (Discard)
4. Not deferred past current time
5. Not excluded by type (e.g., not an epic itself)
6. Parent (if any) is not blocked

### 3.2 Query Interface

Implementations MUST provide a way to query ready work with filters:

```
ready_work(
  priority: int?,           # Filter by priority level
  assignee: string?,        # Filter by assigned entity
  unassigned: bool?,        # Only unassigned items
  labels: set[string]?,     # Must have all these labels
  labels_any: set[string]?, # Must have at least one
  parent: string?,          # Within this hierarchy
  types: set[string]?,      # Include only these types
  exclude_types: set[string]?, # Exclude these types
  limit: int?,              # Maximum results
  sort: enum?               # Ordering strategy
) -> list[WorkItem]
```

### 3.3 Sort Policies

| Policy | Behavior |
|--------|----------|
| `priority` | Highest priority first, then oldest |
| `oldest` | Creation date ascending |
| `hybrid` | Recent items (e.g., 48h) by priority, older by age |

The `hybrid` policy prevents starvation of older low-priority items.

---

## 4. Dependency Resolution

### 4.1 Blocking Semantics

For each blocking dependency type:

**`blocks`**: Direct blocking relationship
- A depends on B via `blocks` → A is blocked while B is not closed

**`parent-child`**: Hierarchical blocking
- If parent P is blocked, all descendants are blocked
- Children do NOT block each other implicitly

**`conditional-blocks`**: Failure-conditional
- A depends on B via `conditional-blocks` → A is blocked while B is open
- When B closes: if close_reason indicates failure, A becomes ready; otherwise A is skipped

**`waits-for`**: Completion gate
- A depends on B via `waits-for` → A waits for B and all B's children to close

### 4.2 Cycle Prevention

The dependency graph MUST be acyclic. Implementations MUST reject operations that would create cycles:

```
Operation: add_dependency(source, target, type)
Precondition: No path exists from target to source
Postcondition: Dependency (source, target) exists
Error: CycleDetectedError if precondition violated
```

### 4.3 Transitive Blocking

Blocking is transitive:
- If A blocks B, and B blocks C, then A transitively blocks C
- Ready work calculation MUST consider transitive blocking

---

## 5. Distributed Synchronization

For multi-agent or multi-device scenarios, implementations need sync capabilities.

### 5.1 Sync Model

**Pull-First Architecture:**
1. Load local state
2. Fetch remote state
3. Compute 3-way merge (base, local, remote)
4. Apply merged result
5. Export local state
6. Push to remote

This ordering prevents race conditions where remote changes arriving during sync are lost.

### 5.2 Merge Strategies

Different field types require different merge strategies:

| Field Type | Strategy | Behavior |
|------------|----------|----------|
| Scalars | Last-Write-Wins (LWW) | Higher `updated_at` wins |
| Sets (labels) | Union | Combine all values |
| Lists (deps) | Union + Dedup | Preserve all unique edges |
| Comments | Append + Dedup | Preserve all, order by timestamp |

### 5.3 Conflict Detection

A **true conflict** exists when:
- Field changed in both local and remote
- Changes are different values
- Neither is the base value

For LWW fields, timestamp breaks ties. For union fields, no conflict is possible.

### 5.4 Resurrection Rule

When an item is deleted locally but edited remotely (or vice versa):
- Edit wins over delete (prevents silent data loss)
- Item is restored with the edit applied
- Discard is cleared

### 5.5 Identity Requirements

IDs MUST be:
- Globally unique without coordination (e.g., hash-based, UUID)
- Hierarchical (e.g., issue-123.1, issue-123.1.1) for human readability
- Stable across sync operations
- Collision probability < 1 in 2^64 for practical workloads

This allows multiple agents to create items simultaneously without conflicts.
---

## 6. Memory Management (Compaction)

Long-running systems accumulate closed work items. Compaction balances history preservation with storage/context efficiency.

### 6.1 Compaction Model

Closed items MAY be compacted after a configurable age:

| Tier | Age | Reduction |
|------|-----|-----------|
| 1 | 30 days | ~70% size reduction |
| 2 | 90 days | ~95% size reduction |

### 6.2 Preserved After Compaction

- ID, title, status, timestamps
- Dependencies (both directions)
- Compaction metadata (when, level, original size)

### 6.3 Discarded After Compaction

- Description, design, notes (replaced with summary)
- Comments (summarized)
- Acceptance criteria

### 6.4 Recovery

Implementations SHOULD provide a way to view original content:

```
restore(item_id) -> OriginalContent?
```

This MAY use version control history, audit logs, or backup storage.

---

## 7. Soft Deletion

### 7.1 Discard Semantics

Deleted items become discards rather than being immediately removed:

```
delete(item_id, reason?)
  item.status = 'discard'
  item.deleted_at = now()
  item.delete_reason = reason
```

### 7.2 Retention

Discards are retained for a configurable period (default: 30 days):

```
prune_discards(older_than: duration)
  for each discard where deleted_at < (now - older_than):
    permanently_delete(discard)
```

### 7.3 Resurrection

Discards can be restored within the retention period:

```
restore_deleted(item_id)
  item.status = 'open'  # or previous status
  item.deleted_at = null
  item.delete_reason = null
```

---

## 8. Agent Integration

### 8.1 Execution Loop

The standard agent work loop:

```
while true:
  items = ready_work(assignee=self)
  if items.empty():
    break  # No more work

  item = items.first()
  update(item.id, status='in_progress')

  result = execute(item)

  if result.success:
    close(item.id, reason=result.summary)
  else:
    # Create follow-up work or escalate
    handle_failure(item, result)
```

### 8.2 Handoff Protocol

For multi-agent or multi-session work:

1. **Claim**: Update status to `in_progress`, set assignee
2. **Work**: Execute the task
3. **Complete**: Close item with reason, or update with progress
4. **Sync**: Push changes to shared state
5. **Release**: Clear assignee if not completing

### 8.3 Session Completion Checklist

Before ending a work session:

1. Update all in-progress items (complete or document state)
2. Create items for discovered/remaining work
3. Sync local state to shared storage
4. Verify sync completed successfully

Work is NOT complete until synced. Unsync'd work may be lost or cause conflicts.

---

## 9. Hierarchical Organization

### 9.1 Molecules and Epics

A **molecule** (or **epic**) is a work item that contains other items:

```
molecule: "User Authentication"
├── task: "Design auth schema"
├── task: "Implement login endpoint"
├── task: "Implement logout endpoint"
├── task: "Add session management"
└── task: "Write tests"
```

### 9.2 Parallelism Default

Children of a molecule are **parallel by default**:
- All children become ready when the molecule is started
- No implicit ordering between siblings
- Dependencies MUST be explicit

### 9.3 Sequential Pipelines

To enforce ordering, add dependencies:

```
"Implement login" blocks "Write tests"
"Implement logout" blocks "Write tests"
# Tests wait for both implementations
```

### 9.4 Completion

A molecule is typically closed when:
- All children are closed, OR
- Explicitly closed (children may remain open), OR
- Closed with reason indicating partial completion

Implementations MAY provide automatic molecule completion when all children close.

---

## 10. Formulas (Templating)

Formulas are reusable work templates that can be instantiated into concrete work items. They encode repeatable patterns—release workflows, feature development pipelines, operational procedures—that can be parameterized and spawned on demand.

### 10.1 Core Concepts

**Formula**: A template defining a work pattern with:
- A root item (typically an epic/molecule)
- Child items representing steps
- Dependencies encoding execution order
- Variables for parameterization

**Instantiation**: The process of creating concrete work items from a formula, with variable substitution applied.

**Phases**: Instantiated work can be:
- **Persistent**: Synced to shared storage, maintains audit trail
- **Ephemeral**: Local-only, auto-cleaned, for operational/diagnostic work

### 10.2 Formula Structure

**Required Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the formula |
| `title` | string | Display name (may contain variables) |
| `steps` | list[Step] | Child items in the formula |

**Optional Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `description` | text | What this formula does |
| `version` | integer | Schema version for migration |
| `vars` | map[string, VarDef] | Variable definitions |
| `phase` | enum | Recommended phase: `persistent` or `ephemeral` |

**Step Definition:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Local identifier within formula |
| `title` | string | Step title (may contain variables) |
| `type` | enum | Issue type: `task`, `bug`, `feature`, etc. |
| `description` | text? | Detailed description |
| `depends_on` | list[string]? | Step IDs this step blocks on |
| `assignee` | string? | Default assignee |

**Example Formula:**
```
formula: "feature-workflow"
description: "Standard feature development pipeline"
version: 1
phase: persistent
vars:
  feature_name:
    description: "Name of the feature"
    required: true
  component:
    description: "Affected component"
    default: "core"
steps:
  - id: design
    title: "Design {{feature_name}}"
    type: task
  - id: implement
    title: "Implement {{feature_name}} in {{component}}"
    type: task
    depends_on: [design]
  - id: test
    title: "Test {{feature_name}}"
    type: task
    depends_on: [implement]
  - id: document
    title: "Document {{feature_name}}"
    type: task
    depends_on: [implement]
```

### 10.3 Variables

Variables enable formula parameterization using `{{variable_name}}` syntax.

**Variable Definition (VarDef):**
| Field | Type | Description |
|-------|------|-------------|
| `description` | string | Explains the variable's purpose |
| `required` | bool | Must be provided at instantiation |
| `default` | string? | Value used if not provided |
| `enum` | list[string]? | Allowed values |
| `pattern` | string? | Regex pattern for validation |

**Substitution Rules:**
- Variables are replaced in: title, description, design, notes, assignee
- Unknown variables are left as-is (no error)
- Missing required variables cause instantiation to fail
- Defaults are applied before substitution

### 10.4 Instantiation

Instantiation creates concrete work items from a formula:

```
instantiate(
  formula_id: string,
  vars: map[string, string],   # Variable values
  assignee: string?,           # Assign root to this entity
  ephemeral: bool?,            # Create ephemeral instance
  parent_id: string?           # Attach to existing item
) -> InstantiationResult

InstantiationResult:
  root_id: string              # ID of created root item
  id_mapping: map[string, string]  # formula step ID -> created item ID
  created_count: int           # Number of items created
```

**Process:**
1. Load formula definition
2. Validate all required variables are provided
3. Apply default values for optional variables
4. Clone each step, substituting variables in all text fields
5. Generate unique IDs for each created item
6. Recreate all dependencies with new IDs
7. If ephemeral, mark items for automatic cleanup
8. Return mapping of formula IDs to created IDs

### 10.5 Phases

**Persistent Phase:**
- Items synced to shared storage (git, database, etc.)
- Full audit trail preserved
- Visible to all agents
- Use for: planned work, features, bugs, releases

**Ephemeral Phase:**
- Items stored locally only
- Not synced to shared storage
- Automatic cleanup available
- Use for: diagnostics, patrols, operational checks

**Phase Transitions:**
- `compress`: Ephemeral → Persistent summary (preserve outcome, discard details)
- `delete`: Ephemeral → Nothing (remove without trace)

### 10.6 Composition

Formulas can be composed to build complex workflows:

**Bond Types:**
| Type | Semantics |
|------|-----------|
| `sequential` | Second formula runs after first completes |
| `parallel` | Both formulas run concurrently |
| `conditional` | Second runs only if first fails |

**Composition Operations:**

```
compose(
  formula_a: string,
  formula_b: string,
  bond_type: enum,
  result_name: string?
) -> Formula

# Creates a new formula combining A and B
```

**Attachment:**
Formulas can be attached to existing work items:

```
attach(
  formula_id: string,
  target_id: string,           # Existing work item
  bond_type: enum,
  vars: map[string, string]
) -> InstantiationResult
```

### 10.7 Distillation

Extract a reusable formula from existing ad-hoc work:

```
distill(
  item_id: string,             # Root of work to templatize
  vars: map[string, string],   # Concrete values to replace with variables
  name: string?                # Name for the formula
) -> Formula
```

**Process:**
1. Load the work item and all descendants
2. For each var mapping, replace concrete values with `{{variable}}`
3. Convert IDs to local step references
4. Extract dependency structure
5. Generate formula definition

**Example:**
```
# After completing ad-hoc work:
distill(
  item_id: "meow-abc123",
  vars: { "v2.0": "version", "auth-service": "component" },
  name: "release-workflow"
)

# Produces formula with {{version}} and {{component}} variables
```

### 10.8 Formula Storage

Formulas MAY be stored as:
- **Embedded**: Work items with a `template` label
- **Files**: Dedicated formula files in a search path
- **Registry**: Central formula repository

Implementations SHOULD support at least one storage mechanism.

**Search Order (typical):**
1. Project-local formulas
2. User-level formulas
3. System/shared formulas

---

## 11. Extension Points

### 11.1 Custom Issue Types

Implementations MAY define domain-specific issue types:

```
register_type(
  name: string,
  required_fields: list[string]?,
  behaviors: TypeBehaviors?
)
```

### 11.2 Custom Dependency Types

Non-blocking dependency types MAY be added:

```
register_dependency_type(
  name: string,
  affects_ready: bool,  # true = blocking
  semantics: string
)
```

### 11.3 Hooks and Events

Implementations MAY provide hooks for:
- Pre/post item creation
- Status transitions
- Sync events
- Ready work queries

### 11.4 Metadata

Items and dependencies MAY carry arbitrary metadata:

```
item.metadata = {
  "estimate": "2h",
  "source_pr": "123",
  "custom_field": "value"
}
```

Implementations SHOULD preserve unknown metadata during sync.

---

## 12. Implementation Considerations

### 12.1 Storage

Any storage backend supporting:
- CRUD operations on entities
- Querying by field values
- Atomic multi-entity updates

Examples: SQL database, document store, flat files, in-memory

### 12.2 Sync Backend

Any mechanism supporting:
- Fetch current remote state
- Push local state
- Detect conflicts

Examples: Git repository, object storage, database replication, custom API

### 12.3 Performance

For large workloads, implementations SHOULD:
- Cache blocked status (compute once, invalidate on dependency change)
- Index frequently-queried fields (status, priority, assignee)
- Batch sync operations

### 12.4 Consistency

Implementations MUST ensure:
- No dependency cycles at any point
- ID uniqueness across all items
- Atomic status transitions

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **Atom** | Synonym for work item |
| **Blocked** | Item cannot proceed due to unmet dependencies |
| **Blocker** | An item that must complete before another can start |
| **Compaction** | Reducing storage size of old closed items |
| **Composition** | Combining formulas via sequential, parallel, or conditional bonds |
| **DAG** | Directed Acyclic Graph (the dependency structure) |
| **Distillation** | Extracting a reusable formula from existing ad-hoc work |
| **Epic** | Work item containing other items (organizational) |
| **Ephemeral** | Instance phase: local-only, not synced, auto-cleaned |
| **Formula** | Reusable template defining a work pattern with variables |
| **Instantiation** | Creating concrete work items from a formula |
| **LWW** | Last-Write-Wins conflict resolution |
| **Molecule** | Epic with execution intent (semantic distinction) |
| **Persistent** | Instance phase: synced to shared storage, full audit trail |
| **Ready** | Item with no blockers, available for work |
| **Discard** | Soft-deleted item awaiting permanent removal |
| **Variable** | Placeholder in formula (`{{name}}`) replaced during instantiation |

## Appendix B: Example Workflows

### B.1 Simple Sequential Pipeline

```
Create: "Step 1" (task)
Create: "Step 2" (task)
Create: "Step 3" (task)
Add: "Step 2" blocks-on "Step 1"
Add: "Step 3" blocks-on "Step 2"

Ready: [Step 1]
Complete: Step 1
Ready: [Step 2]
Complete: Step 2
Ready: [Step 3]
Complete: Step 3
Ready: []
```

### B.2 Parallel with Join

```
Create: "Process" (epic)
Create: "Part A" (task, parent=Process)
Create: "Part B" (task, parent=Process)
Create: "Combine" (task, parent=Process)
Add: "Combine" waits-for "Part A"
Add: "Combine" waits-for "Part B"

Ready: [Part A, Part B]
Complete: Part A
Ready: [Part B]  # Combine still waiting
Complete: Part B
Ready: [Combine]
Complete: Combine
```

### B.3 Conditional Error Handling

```
Create: "Try Operation" (task)
Create: "Handle Failure" (task)
Add: "Handle Failure" conditional-blocks-on "Try Operation"

Ready: [Try Operation]
Complete: Try Operation (reason: "failed: timeout")
Ready: [Handle Failure]  # Runs because failure detected

# Alternative:
Complete: Try Operation (reason: "success")
Ready: []  # Handle Failure skipped
```

### B.4 Formula Instantiation

```
# Define a formula
Formula: "deploy-service"
  vars:
    service: required
    env: default="staging"
  steps:
    - id: build
      title: "Build {{service}}"
    - id: test
      title: "Test {{service}}"
      depends_on: [build]
    - id: deploy
      title: "Deploy {{service}} to {{env}}"
      depends_on: [test]

# Instantiate with variables
Instantiate: "deploy-service"
  vars: { service: "auth-api", env: "production" }

# Result: Creates 3 work items
Created: "Build auth-api" (task, id=meow-001)
Created: "Test auth-api" (task, id=meow-002, blocks-on meow-001)
Created: "Deploy auth-api to production" (task, id=meow-003, blocks-on meow-002)

Ready: [meow-001]
Complete: meow-001
Ready: [meow-002]
Complete: meow-002
Ready: [meow-003]
Complete: meow-003
Ready: []
```

### B.5 Formula Composition

```
# Two existing formulas
Formula: "feature-dev"
  steps: [design, implement, review]

Formula: "deploy-pipeline"
  steps: [build, test, deploy]

# Compose sequentially
Compose: "feature-dev" + "deploy-pipeline"
  bond_type: sequential
  result: "feature-to-prod"

# Result: Combined formula where deploy-pipeline
# runs after feature-dev completes
Ready: [design]
Complete: design, implement, review  # feature-dev phase
Ready: [build]                       # deploy-pipeline starts
Complete: build, test, deploy
Ready: []
```
