# frozen_string_literal: true

require 'fileutils'
require 'json'

module Eluent
  module Sync
    module Concerns
      # Atom claim operations for the ledger worktree.
      #
      # Atoms are work units that agents can claim exclusive ownership of.
      # This module reads and writes atom records in the worktree's JSONL file,
      # implementing the claim/release state machine:
      #
      #   open -> in_progress -> closed/discard
      #          (claimable)    (terminal, cannot reclaim)
      #
      # All file operations target the worktree, not the main working directory.
      #
      # @note Requires including class to provide:
      #   - #worktree_ledger_dir - path to .eluent/ in the worktree
      #   - #clock - Time-like object responding to #now
      #   - #commit_ledger_changes - commits pending changes to the worktree
      # rubocop:disable Metrics/ModuleLength -- Cohesive atom operations; extracting would scatter related logic
      module LedgerAtomOperations
        private

        # Attempts to claim an atom for an agent.
        #
        # Claim semantics:
        # - Atoms in 'open' status can be claimed by any agent
        # - Atoms in 'in_progress' status are already claimed; same-agent is idempotent
        # - Atoms in terminal states ('closed', 'discard') cannot be claimed
        #
        # @return [ClaimResult] with success status and claimed_by agent
        def attempt_claim(atom_id:, agent_id:)
          return claim_failed('atom_id cannot be nil or empty') if atom_id.nil? || atom_id.to_s.strip.empty?
          return claim_failed('agent_id cannot be nil or empty') if agent_id.nil? || agent_id.to_s.strip.empty?

          atom = find_atom_in_worktree(atom_id)
          return claim_failed("Atom not found: #{atom_id}") unless atom

          case atom[:status]
          when 'closed', 'discard'
            claim_failed("Cannot claim atom in #{atom[:status]} state")
          when 'in_progress'
            handle_existing_claim(atom, agent_id)
          else
            perform_claim(atom_id, agent_id)
          end
        end

        def handle_existing_claim(atom, agent_id)
          if atom[:assignee] == agent_id
            claim_succeeded(agent_id) # Idempotent: already own it
          else
            claim_failed("Already claimed by #{atom[:assignee]}", claimed_by: atom[:assignee])
          end
        end

        def perform_claim(atom_id, agent_id)
          update_atom_in_worktree(atom_id, status: 'in_progress', assignee: agent_id)
          commit_ledger_changes(message: "Claim #{atom_id} for #{agent_id}")
          claim_succeeded(agent_id)
        end

        def claim_succeeded(agent_id)
          LedgerSyncer::ClaimResult.new(success: true, claimed_by: agent_id)
        end

        def claim_failed(error, claimed_by: nil)
          LedgerSyncer::ClaimResult.new(success: false, error: error, claimed_by: claimed_by)
        end

        # Finds an atom record by ID in the worktree's data file.
        #
        # Scans the JSONL file line by line for memory efficiency on large ledgers.
        # Malformed JSON lines are skipped silently to allow partial recovery.
        #
        # @param atom_id [String] the atom identifier to find
        # @return [Hash, nil] the atom record with symbolized keys, or nil if not found
        def find_atom_in_worktree(atom_id)
          data_file = File.join(worktree_ledger_dir, 'data.jsonl')
          return nil unless File.exist?(data_file)

          File.foreach(data_file) do |line|
            record = JSON.parse(line, symbolize_names: true)
            return record if record[:_type] == 'atom' && record[:id] == atom_id
          rescue JSON::ParserError
            next
          end
          nil
        end

        # Updates an atom's fields in the worktree's data file.
        #
        # Reads the entire file, modifies the matching record in memory, and
        # writes back atomically via temp file rename. Sets updated_at timestamp
        # automatically.
        #
        # @param atom_id [String] the atom identifier to update
        # @param updates [Hash] field updates to apply (status:, assignee:, etc.)
        # @raise [LedgerSyncerError] if the data file doesn't exist or write fails
        def update_atom_in_worktree(atom_id, **updates)
          data_file = File.join(worktree_ledger_dir, 'data.jsonl')
          raise LedgerSyncerError, "Ledger data file not found: #{data_file}" unless File.exist?(data_file)

          lines = File.readlines(data_file)
          updated_lines = lines.map { |line| update_line_if_matching(line, atom_id, updates) }

          # Write atomically via temp file to prevent corruption from concurrent writes
          temp_file = "#{data_file}.#{Process.pid}.tmp"
          begin
            File.write(temp_file, updated_lines.join)
            File.rename(temp_file, data_file)
          rescue SystemCallError => e
            FileUtils.rm_f(temp_file)
            raise LedgerSyncerError, "Failed to update atom #{atom_id}: #{e.message}"
          end
        end

        def update_line_if_matching(line, atom_id, updates)
          record = JSON.parse(line, symbolize_names: true)
          return line unless record[:_type] == 'atom' && record[:id] == atom_id

          record = record.merge(updates)
          record[:updated_at] = clock.now.utc.iso8601
          "#{JSON.generate(record)}\n"
        rescue JSON::ParserError
          line # Preserve malformed lines unchanged
        end

        # Releases multiple atoms in a single file write (batch operation).
        #
        # More efficient than calling update_atom_in_worktree N times when
        # releasing multiple stale claims.
        #
        # @param atom_ids [Array<String>] atom IDs to release
        # @raise [LedgerSyncerError] if the data file doesn't exist or write fails
        def release_atoms_in_worktree(atom_ids)
          return if atom_ids.empty?

          data_file = File.join(worktree_ledger_dir, 'data.jsonl')
          raise LedgerSyncerError, "Ledger data file not found: #{data_file}" unless File.exist?(data_file)

          id_set = atom_ids.to_set
          lines = File.readlines(data_file)
          updated_lines = lines.map { |line| release_line_if_matching(line, id_set) }

          temp_file = "#{data_file}.#{Process.pid}.tmp"
          begin
            File.write(temp_file, updated_lines.join)
            File.rename(temp_file, data_file)
          rescue SystemCallError => e
            FileUtils.rm_f(temp_file)
            raise LedgerSyncerError, "Failed to release atoms: #{e.message}"
          end
        end

        def release_line_if_matching(line, id_set)
          record = JSON.parse(line, symbolize_names: true)
          return line unless record[:_type] == 'atom' && id_set.include?(record[:id])

          record[:status] = 'open'
          record[:assignee] = nil
          record[:updated_at] = clock.now.utc.iso8601
          "#{JSON.generate(record)}\n"
        rescue JSON::ParserError
          line
        end

        # Updates only the timestamp of an atom (heartbeat operation).
        #
        # Unlike `update_atom_in_worktree`, this method doesn't modify any fields
        # except `updated_at`. Used to keep claims alive without changing state.
        #
        # @param atom_id [String] the atom identifier to touch
        # @return [Boolean] true if atom was found and touched, false if not found
        # @raise [LedgerSyncerError] if the data file doesn't exist or write fails
        def touch_atom_timestamp(atom_id)
          data_file = File.join(worktree_ledger_dir, 'data.jsonl')
          raise LedgerSyncerError, "Ledger data file not found: #{data_file}" unless File.exist?(data_file)

          lines = File.readlines(data_file)
          found = false
          updated_lines = lines.map do |line|
            result, was_found = touch_line_if_matching(line, atom_id)
            found ||= was_found
            result
          end

          return false unless found

          temp_file = "#{data_file}.#{Process.pid}.tmp"
          begin
            File.write(temp_file, updated_lines.join)
            File.rename(temp_file, data_file)
          rescue SystemCallError => e
            FileUtils.rm_f(temp_file)
            raise LedgerSyncerError, "Failed to touch atom #{atom_id}: #{e.message}"
          end

          true
        end

        # Returns [updated_line, was_matched] tuple.
        def touch_line_if_matching(line, atom_id)
          record = JSON.parse(line, symbolize_names: true)
          return [line, false] unless record[:_type] == 'atom' && record[:id] == atom_id

          record[:updated_at] = clock.now.utc.iso8601
          ["#{JSON.generate(record)}\n", true]
        rescue JSON::ParserError
          [line, false]
        end
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
