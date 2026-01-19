# frozen_string_literal: true

module Eluent
  module Storage
    # Manages all path resolution for a repository.
    # Single responsibility: knows where things live on disk.
    class Paths
      ELUENT_DIR = '.eluent'
      DATA_FILE = 'data.jsonl' # Primary storage: atoms, bonds, comments (synced via git)
      EPHEMERAL_FILE = 'ephemeral.jsonl' # Local-only data: scratchpad, drafts (gitignored)
      CONFIG_FILE = 'config.yaml' # Repository configuration: defaults, custom statuses

      attr_reader :root

      def initialize(root_path)
        @root = File.expand_path(root_path)
      end

      def eluent_dir = File.join(root, ELUENT_DIR)
      def data_file = File.join(eluent_dir, DATA_FILE)
      def ephemeral_file = File.join(eluent_dir, EPHEMERAL_FILE)
      def config_file = File.join(eluent_dir, CONFIG_FILE)
      def formulas_dir = File.join(eluent_dir, 'formulas')
      def plugins_dir = File.join(eluent_dir, 'plugins')
      def gitignore_file = File.join(eluent_dir, '.gitignore')
      def sync_state_file = File.join(eluent_dir, '.sync-state')
      def git_dir = File.join(root, '.git')
      def git_config_file = File.join(git_dir, 'config')

      def data_file_exists?
        File.exist?(data_file)
      end

      # Backward-compatible alias
      alias initialized? data_file_exists?

      def ephemeral_exists?
        File.exist?(ephemeral_file)
      end

      def git_repo?
        Dir.exist?(git_dir)
      end
    end
  end
end
