# frozen_string_literal: true

module Eluent
  module Agents
    # Tool definitions for AI function calling
    # Provides shared schemas for both Claude and OpenAI executors
    # rubocop:disable Metrics/ModuleLength
    module ToolDefinitions
      TOOLS = {
        list_items: {
          description: 'List work items with optional filters',
          parameters: {
            type: 'object',
            properties: {
              status: {
                type: 'string',
                enum: %w[open in_progress blocked deferred closed],
                description: 'Filter by status'
              },
              type: {
                type: 'string',
                description: 'Filter by issue type (task, feature, bug, etc.)'
              },
              assignee: {
                type: 'string',
                description: 'Filter by assignee'
              },
              labels: {
                type: 'array',
                items: { type: 'string' },
                description: 'Filter by labels (all must match)'
              },
              include_closed: {
                type: 'boolean',
                description: 'Include closed items in results'
              }
            },
            required: []
          }
        },

        show_item: {
          description: 'Get details of a specific work item',
          parameters: {
            type: 'object',
            properties: {
              id: {
                type: 'string',
                description: 'Item ID (full or short prefix)'
              }
            },
            required: ['id']
          }
        },

        create_item: {
          description: 'Create a new work item',
          parameters: {
            type: 'object',
            properties: {
              title: {
                type: 'string',
                description: 'Item title'
              },
              description: {
                type: 'string',
                description: 'Detailed description'
              },
              type: {
                type: 'string',
                description: 'Issue type (task, feature, bug, artifact)'
              },
              priority: {
                type: 'integer',
                minimum: 0,
                maximum: 4,
                description: 'Priority level (0=highest, 4=lowest)'
              },
              assignee: {
                type: 'string',
                description: 'Assignee identifier'
              },
              labels: {
                type: 'array',
                items: { type: 'string' },
                description: 'Labels to apply'
              }
            },
            required: ['title']
          }
        },

        update_item: {
          description: 'Update an existing work item',
          parameters: {
            type: 'object',
            properties: {
              id: {
                type: 'string',
                description: 'Item ID to update'
              },
              title: {
                type: 'string',
                description: 'New title'
              },
              description: {
                type: 'string',
                description: 'New description'
              },
              priority: {
                type: 'integer',
                minimum: 0,
                maximum: 4,
                description: 'New priority level'
              },
              status: {
                type: 'string',
                enum: %w[open in_progress blocked deferred],
                description: 'New status'
              },
              assignee: {
                type: 'string',
                description: 'New assignee'
              },
              labels: {
                type: 'array',
                items: { type: 'string' },
                description: 'Labels to set (replaces existing)'
              }
            },
            required: ['id']
          }
        },

        close_item: {
          description: 'Close a work item',
          parameters: {
            type: 'object',
            properties: {
              id: {
                type: 'string',
                description: 'Item ID to close'
              },
              reason: {
                type: 'string',
                description: 'Reason for closing (optional)'
              }
            },
            required: ['id']
          }
        },

        ready_work: {
          description: 'Get list of ready (unblocked) work items',
          parameters: {
            type: 'object',
            properties: {
              sort: {
                type: 'string',
                enum: %w[priority oldest hybrid],
                description: 'Sort order for results'
              },
              type: {
                type: 'string',
                description: 'Filter by issue type'
              },
              assignee: {
                type: 'string',
                description: 'Filter by assignee'
              },
              limit: {
                type: 'integer',
                minimum: 1,
                maximum: 50,
                description: 'Maximum number of items to return'
              }
            },
            required: []
          }
        },

        add_dependency: {
          description: 'Add a dependency between work items',
          parameters: {
            type: 'object',
            properties: {
              source_id: {
                type: 'string',
                description: 'ID of item that blocks'
              },
              target_id: {
                type: 'string',
                description: 'ID of item that is blocked'
              },
              dependency_type: {
                type: 'string',
                enum: %w[blocks needs_review relates_to],
                description: 'Type of dependency'
              }
            },
            required: %w[source_id target_id]
          }
        },

        add_comment: {
          description: 'Add a comment to a work item',
          parameters: {
            type: 'object',
            properties: {
              id: {
                type: 'string',
                description: 'Item ID to comment on'
              },
              content: {
                type: 'string',
                description: 'Comment content'
              }
            },
            required: %w[id content]
          }
        }
      }.freeze

      class << self
        # Format tools for Claude API
        def for_claude
          TOOLS.map do |name, definition|
            {
              name: name.to_s,
              description: definition[:description],
              input_schema: definition[:parameters]
            }
          end
        end

        # Format tools for OpenAI API
        def for_openai
          TOOLS.map do |name, definition|
            {
              type: 'function',
              function: {
                name: name.to_s,
                description: definition[:description],
                parameters: definition[:parameters]
              }
            }
          end
        end

        # Get a specific tool definition
        def [](name)
          TOOLS[name.to_sym]
        end

        # Get all tool names
        def names
          TOOLS.keys
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
