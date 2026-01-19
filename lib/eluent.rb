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
require_relative 'eluent/sync/sync_state'
require_relative 'eluent/sync/git_adapter'
require_relative 'eluent/sync/conflict_resolver'
require_relative 'eluent/sync/merge_engine'
require_relative 'eluent/sync/pull_first_orchestrator'

# Registry extensions
require_relative 'eluent/registry/repo_registry'

# Daemon
require_relative 'eluent/daemon/protocol'
require_relative 'eluent/daemon/client'
require_relative 'eluent/daemon/command_router'
require_relative 'eluent/daemon/server'
