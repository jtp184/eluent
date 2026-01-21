# frozen_string_literal: true

require 'shellwords'
require 'fileutils'

module Eluent
  module Agents
    module Concerns
      # Provides tmux session management for process-based executors.
      #
      # Responsibilities:
      # - Session lifecycle: create, monitor, destroy tmux sessions
      # - Context files: write task details to markdown files for CLI consumption
      # - Working directory resolution
      #
      # rubocop:disable Metrics/ModuleLength -- cohesive concern, splitting reduces clarity
      module TmuxSessionManager
        SESSION_START_TIMEOUT = 5
        CONTEXT_FILE_SANITIZER = %r{[/\\:*?"<>|]}

        private

        # Session lifecycle

        def start_session(name, atom, prompt)
          context_file = write_context_file(atom, prompt)
          working_dir = resolve_working_directory
          cmd = "#{claude_code_command} -p #{Shellwords.escape(context_file)}"

          run_tmux('new-session', '-d', '-s', name, '-c', working_dir, cmd) or
            raise session_error('Failed to create tmux session', name, :create)

          wait_for_session(name) or
            raise session_error('Session created but not accessible', name, :create)
        end

        def wait_for_session(name, timeout: SESSION_START_TIMEOUT)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            return true if session_exists?(name)
            return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.1
          end
        end

        def session_exists?(name)
          return false if name.to_s.empty?

          system("tmux has-session -t #{Shellwords.escape(name)} 2>/dev/null")
        end

        def capture_output(name)
          return '' if name.to_s.empty?

          `tmux capture-pane -p -t #{Shellwords.escape(name)} -S -1000`
        end

        def destroy_session(name)
          return false if name.to_s.empty?

          system("tmux kill-session -t #{Shellwords.escape(name)} 2>/dev/null")
        end

        def cleanup_session(name)
          destroy_session(name) unless name.to_s.empty?
          cleanup_context_file
        end

        def run_tmux(*)
          system('tmux', *)
        end

        def claude_code_command
          configuration.claude_code_path
        end

        def resolve_working_directory
          dir = configuration.working_directory || Dir.pwd
          unless Dir.exist?(dir)
            raise session_error("Working directory does not exist: #{dir}", nil,
                                :validate_directory)
          end

          dir
        end

        # Context file management

        def write_context_file(atom, system_prompt)
          @context_file_path = nil # Reset to avoid stale state if executor is reused
          @context_file_path = context_file_path(atom)
          FileUtils.mkdir_p(File.dirname(@context_file_path))
          File.write(@context_file_path, build_context_content(atom, system_prompt))
          @context_file_path
        rescue Errno::EACCES, Errno::EROFS => e
          raise session_error("Cannot write context file: #{e.message}", nil, :write_context)
        end

        def cleanup_context_file
          return unless @context_file_path && File.exist?(@context_file_path)

          File.delete(@context_file_path)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EROFS
          # Ignore cleanup failures
        end

        def context_file_path(atom)
          dir = configuration.context_directory
          safe_id = atom.id.to_s.gsub(CONTEXT_FILE_SANITIZER, '_')
          File.join(resolve_working_directory, dir, "#{safe_id}.md")
        end

        def build_context_content(atom, system_prompt)
          [
            system_prompt,
            work_item_section(atom),
            instructions_section(atom)
          ].compact.join("\n\n")
        end

        def work_item_section(atom)
          <<~MARKDOWN
            # Work Item: #{atom.id}

            **Title:** #{atom.title}
            **Type:** #{atom.issue_type}
            **Priority:** #{atom.priority}
            **Status:** #{atom.status}

            ## Description

            #{atom.description || '_No description provided_'}
          MARKDOWN
        end

        def instructions_section(atom)
          <<~MARKDOWN
            ## Instructions

            Complete this task. When finished, run:

            ```bash
            el close #{atom.id} --reason "Brief summary of work completed"
            ```

            If the task cannot be completed now but may be revisited later:

            ```bash
            el update #{atom.id} --status deferred
            el comment add #{atom.id} "Reason this task is deferred..."
            ```

            If the task should not be completed at all:

            ```bash
            el update #{atom.id} --status wont_do
            el comment add #{atom.id} "Reason this task will not be done..."
            ```
          MARKDOWN
        end
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
