# frozen_string_literal: true

require 'forwardable'

require_relative 'eluent/version'

module Eluent
  class Error < StandardError; end
end

# Model mixins (loaded first as dependencies)
require_relative 'eluent/models/mixins/extendable_collection'
require_relative 'eluent/models/mixins/validations'

# Model value types
require_relative 'eluent/models/status'
require_relative 'eluent/models/issue_type'
require_relative 'eluent/models/dependency_type'

# Model entities
require_relative 'eluent/models/atom'
require_relative 'eluent/models/bond'
require_relative 'eluent/models/comment'

# Storage
require_relative 'eluent/storage/prefix_trie'
require_relative 'eluent/storage/indexer'
require_relative 'eluent/storage/serializers/atom_serializer'
require_relative 'eluent/storage/serializers/bond_serializer'
require_relative 'eluent/storage/serializers/comment_serializer'
require_relative 'eluent/storage/jsonl_repository'
require_relative 'eluent/storage/global_paths'

# Registry
require_relative 'eluent/registry/id_generator'
require_relative 'eluent/registry/id_resolver'

# Graph
require_relative 'eluent/graph/dependency_graph'
require_relative 'eluent/graph/cycle_detector'
require_relative 'eluent/graph/blocking_resolver'

# Lifecycle
require_relative 'eluent/lifecycle/readiness_calculator'

# Sync
require_relative 'eluent/sync/errors'
require_relative 'eluent/sync/sync_state'
require_relative 'eluent/sync/ledger_sync_state'
require_relative 'eluent/sync/git_adapter'
require_relative 'eluent/sync/conflict_resolver'
require_relative 'eluent/sync/merge_engine'
require_relative 'eluent/sync/pull_first_orchestrator'
require_relative 'eluent/sync/ledger_syncer'

# Registry extensions
require_relative 'eluent/registry/repo_registry'
require_relative 'eluent/registry/repo_context'

# Daemon
require_relative 'eluent/daemon/protocol'
require_relative 'eluent/daemon/client'
require_relative 'eluent/daemon/command_router'
require_relative 'eluent/daemon/server'

# Formulas
require_relative 'eluent/models/formula'
require_relative 'eluent/formulas/parser'
require_relative 'eluent/formulas/variable_resolver'
require_relative 'eluent/formulas/instantiator'
require_relative 'eluent/formulas/distiller'
require_relative 'eluent/formulas/composer'

# Compaction
require_relative 'eluent/compaction/summarizer'
require_relative 'eluent/compaction/compactor'
require_relative 'eluent/compaction/restorer'

# Plugins
require_relative 'eluent/plugins/errors'
require_relative 'eluent/plugins/hooks_manager'
require_relative 'eluent/plugins/hook_context'
require_relative 'eluent/plugins/plugin_registry'
require_relative 'eluent/plugins/plugin_definition_context'
require_relative 'eluent/plugins/gem_loader'
require_relative 'eluent/plugins/plugin_manager'

# Agents
require_relative 'eluent/agents/errors'
require_relative 'eluent/agents/configuration'
require_relative 'eluent/agents/tool_definitions'
require_relative 'eluent/agents/agent_executor'
require_relative 'eluent/agents/concerns/timeout_handler'
require_relative 'eluent/agents/concerns/http_error_handler'
require_relative 'eluent/agents/concerns/json_parsing'
require_relative 'eluent/agents/implementations/claude_executor'
require_relative 'eluent/agents/implementations/openai_executor'
require_relative 'eluent/agents/execution_loop'
