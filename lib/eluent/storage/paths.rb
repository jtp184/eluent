# frozen_string_literal: true

module Eluent
  module Storage
    # Manages all path resolution for a repository
    # Single responsibility: knows where things live on disk
    class Paths
      ELUENT_DIR = '.eluent'
      DATA_FILE = 'data.jsonl'
      EPHEMERAL_FILE = 'ephemeral.jsonl'
      CONFIG_FILE = 'config.yaml'

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

      def initialized?
        File.exist?(data_file)
      end

      def ephemeral_exists?
        File.exist?(ephemeral_file)
      end

      def git_repo?
        Dir.exist?(git_dir)
      end
    end
  end
end
