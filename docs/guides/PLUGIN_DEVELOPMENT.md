# Plugin Development Guide

This guide covers how to extend Eluent with plugins. Plugins can add lifecycle hooks, custom commands, and new types to customize Eluent's behavior.

## Overview

Eluent loads plugins from three sources:

1. **Local plugins** - `.eluent/plugins/*.rb` in your repository
2. **Global plugins** - `~/.eluent/plugins/*.rb` in your home directory
3. **Gem plugins** - Any installed gem named `eluent-*`

Plugins can:
- React to lifecycle events (create, update, close, etc.)
- Add custom CLI commands
- Register new issue types, statuses, and dependency types

## Quick Start

Create a simple plugin at `.eluent/plugins/my_plugin.rb`:

```ruby
# frozen_string_literal: true

Eluent::Plugins.register 'my-plugin' do
  # Log when items are created
  after_create do |ctx|
    puts "Created: #{ctx.item.title}"
  end
end
```

That's it! The plugin will load automatically when you run any `el` command.

## Plugin Registration

All plugins use the `Eluent::Plugins.register` DSL:

```ruby
Eluent::Plugins.register 'plugin-name' do
  # Plugin definition goes here
end
```

The block is evaluated in a `PluginDefinitionContext` which provides methods for registering hooks, commands, and type extensions.

## Lifecycle Hooks

Hooks let you react to events in the item lifecycle. There are 8 lifecycle hooks:

| Hook | When it fires |
|------|---------------|
| `before_create` | Before an atom is created |
| `after_create` | After an atom is created |
| `before_close` | Before an atom is closed |
| `after_close` | After an atom is closed |
| `before_update` | Before an atom is updated |
| `after_update` | After an atom is updated |
| `on_status_change` | When an atom's status changes |
| `on_sync` | During git sync operations |

### Registering Hooks

```ruby
Eluent::Plugins.register 'validation-plugin' do
  # Basic hook
  before_create do |ctx|
    validate_title(ctx.item.title)
  end

  # Hook with priority (lower = runs first, default = 100)
  before_create(priority: 50) do |ctx|
    # This runs before the default priority hooks
  end

  after_update do |ctx|
    log_changes(ctx.item, ctx.changes)
  end
end
```

### Hook Context

Every hook receives a `HookContext` object with access to:

```ruby
ctx.item        # The atom being operated on
ctx.repo        # The JsonlRepository instance
ctx.changes     # Hash of changes (for update hooks)
ctx.event       # The event type (:before_create, :after_update, etc.)
ctx.metadata    # Additional context data

# Convenience methods
ctx[field]              # Access item fields safely
ctx.before_hook?        # True if this is a before_* hook
ctx.after_hook?         # True if this is an after_* hook
ctx.old_value(:title)   # Get old value of a changed field
ctx.new_value(:title)   # Get new value of a changed field
ctx.halted?             # Check if operation was halted

# Abort an operation (before hooks only)
ctx.halt!('Reason for aborting')
```

### Aborting Operations

In `before_*` hooks, you can abort the operation using `halt!`:

```ruby
Eluent::Plugins.register 'enforce-labels' do
  before_create do |ctx|
    if ctx.item.labels.empty?
      ctx.halt!('Items must have at least one label')
    end
  end
end
```

When `halt!` is called:
1. The operation is cancelled
2. An error message is shown to the user
3. No further hooks are invoked

### Changes Hash

For `before_update` and `after_update` hooks, the `changes` hash shows what's changing:

```ruby
# ctx.changes structure:
{
  title: { from: 'Old Title', to: 'New Title' },
  status: { from: Status[:open], to: Status[:closed] }
}
```

Use `old_value` and `new_value` helpers:

```ruby
after_update do |ctx|
  if ctx.old_value(:status) != ctx.new_value(:status)
    notify_status_change(ctx.item)
  end
end
```

## Priority System

Hooks run in priority order (lower numbers first):

- Priority 0-49: Early hooks (validation, preprocessing)
- Priority 50-99: Normal-early hooks
- Priority 100: Default priority
- Priority 101-199: Normal-late hooks
- Priority 200+: Late hooks (cleanup, notifications)

```ruby
Eluent::Plugins.register 'early-validation' do
  before_create(priority: 10) do |ctx|
    # Runs very early
  end
end

Eluent::Plugins.register 'late-notification' do
  after_create(priority: 200) do |ctx|
    # Runs after most other hooks
  end
end
```

If two hooks have the same priority, they run in registration order.

## Custom Commands

Plugins can add new CLI commands:

```ruby
Eluent::Plugins.register 'time-tracker' do
  command 'track', description: 'Log time on an item' do |args|
    item_id, duration = args
    # Implementation here
    puts "Logged #{duration} on #{item_id}"
  end
end
```

Usage: `el track ABC123 2h`

Command names must not conflict with built-in commands.

## Type Extensions

Plugins can register new types to extend Eluent's vocabulary.

### Issue Types

```ruby
Eluent::Plugins.register 'issue-types' do
  # Concrete type (can be instantiated)
  register_issue_type :spike

  # Abstract type (container only, like epic)
  register_issue_type :milestone, abstract: true
end
```

### Status Types

```ruby
Eluent::Plugins.register 'custom-statuses' do
  register_status_type :review,
    from: [:in_progress],  # Can only transition from in_progress
    to: [:closed, :open]   # Can only transition to closed or open
end
```

### Dependency Types

```ruby
Eluent::Plugins.register 'custom-deps' do
  # Blocking dependency (affects readiness)
  register_dependency_type :requires_approval, blocking: true

  # Informational dependency (no blocking effect)
  register_dependency_type :inspired_by, blocking: false
end
```

## Gem Distribution

To distribute a plugin as a gem:

1. Name your gem `eluent-<name>` (e.g., `eluent-jira-sync`)

2. Create `lib/eluent/plugin.rb` as the entry point:

```ruby
# lib/eluent/plugin.rb
require 'eluent'

Eluent::Plugins.register 'jira-sync' do
  # Plugin implementation
end
```

3. Your gemspec should include:

```ruby
Gem::Specification.new do |spec|
  spec.name = 'eluent-jira-sync'
  # ...
end
```

The gem will be automatically discovered and loaded when installed.

## Testing Plugins

Use `Eluent::Plugins.reset!` to clear state between tests:

```ruby
RSpec.describe 'MyPlugin' do
  after { Eluent::Plugins.reset! }

  it 'validates titles' do
    Eluent::Plugins.register 'test-plugin' do
      before_create do |ctx|
        ctx.halt!('Title too short') if ctx.item.title.length < 5
      end
    end

    # Test the hook behavior
    manager = Eluent::Plugins.manager
    context = manager.create_context(
      item: build_atom(title: 'Hi'),
      repo: mock_repo,
      event: :before_create
    )

    result = manager.invoke_hook(:before_create, context)
    expect(result.halted).to be true
    expect(result.reason).to eq('Title too short')
  end
end
```

### Testing with the Manager

```ruby
let(:manager) { Eluent::Plugins::PluginManager.new }

after { manager.reset! }

it 'registers hooks' do
  manager.register('test') do
    before_create { |ctx| }
  end

  expect(manager.hooks.registered?(:before_create)).to be true
end
```

## Complete Example

Here's a full-featured plugin that enforces workflow rules:

```ruby
# .eluent/plugins/workflow_enforcement.rb
# frozen_string_literal: true

Eluent::Plugins.register 'workflow-enforcement' do
  # Validate items have required fields
  before_create(priority: 10) do |ctx|
    item = ctx.item

    ctx.halt!('Title is required') if item.title.nil? || item.title.empty?
    ctx.halt!('Bugs must have a priority') if item.issue_type.to_sym == :bug && item.priority.nil?
  end

  # Auto-assign labels based on type
  before_create(priority: 50) do |ctx|
    item = ctx.item
    type_label = "type:#{item.issue_type}"
    item.labels = (item.labels + [type_label]).uniq
  end

  # Log status transitions
  on_status_change do |ctx|
    old_status = ctx.old_value(:status)
    new_status = ctx.new_value(:status)
    puts "[Workflow] #{ctx.item.id}: #{old_status} -> #{new_status}"
  end

  # Notify on close
  after_close do |ctx|
    # Send notification, update external systems, etc.
    notify_stakeholders(ctx.item) if ctx.item.priority&.<=(2)
  end

  # Register custom status for code review
  register_status_type :in_review,
    from: [:in_progress],
    to: [:open, :closed]

  # Add a quick-status command
  command 'review', description: 'Move item to review status' do |args|
    item_id = args.first
    # Implementation would update item status
    puts "#{item_id} moved to review"
  end

  private

  def notify_stakeholders(item)
    # External notification logic
  end
end
```

## Error Handling

Plugins should handle errors gracefully:

```ruby
Eluent::Plugins.register 'safe-plugin' do
  after_create do |ctx|
    begin
      external_api_call(ctx.item)
    rescue ExternalAPIError => e
      # Log but don't crash
      warn "[safe-plugin] API call failed: #{e.message}"
    end
  end
end
```

If a hook raises an unhandled exception:
- Hook execution stops immediately
- The error is captured in the `HookResult`
- For `before_*` hooks, the operation is aborted
- For `after_*` hooks, the operation has already completed

## Plugin Errors

The plugin system defines several error types:

- `Eluent::Plugins::PluginError` - Base error class
- `Eluent::Plugins::PluginLoadError` - Plugin file failed to load
- `Eluent::Plugins::HookAbortError` - Raised by `halt!` to abort operations
- `Eluent::Plugins::InvalidPluginError` - Invalid plugin definition

## Best Practices

1. **Use meaningful priorities** - Reserve low priorities (0-49) for validation, high priorities (200+) for notifications

2. **Keep hooks fast** - Hooks run synchronously; slow hooks slow down the CLI

3. **Handle errors gracefully** - Don't let external failures crash the workflow

4. **Document your commands** - Use the `description:` parameter

5. **Test thoroughly** - Use `reset!` to ensure test isolation

6. **Namespace carefully** - Choose unique plugin and command names to avoid conflicts

7. **Log sparingly** - Use `warn` for important messages, avoid cluttering output
