# frozen_string_literal: true

module Eluent
  module CLI
    module Commands
      # Initialize .eluent/ directory
      class Init < BaseCommand
        usage do
          program 'el init'
          desc 'Initialize a new .eluent directory in the current repository'
          example 'el init', 'Initialize with auto-detected repo name'
          example 'el init --name myproject', 'Initialize with custom repo name'
        end

        option :name do
          short '-n'
          long '--name NAME'
          desc 'Repository name (defaults to git remote or directory name)'
        end

        flag :help do
          short '-h'
          long '--help'
          desc 'Print usage'
        end

        def run
          if params[:help]
            puts help
            return 0
          end

          repo = Storage::JsonlRepository.new(Dir.pwd)

          return error('REPO_EXISTS', ".eluent already exists in #{Dir.pwd}") if repo.initialized?

          repo.init(repo_name: params[:name])

          success("Initialized .eluent in #{Dir.pwd}", data: {
                    path: File.join(Dir.pwd, '.eluent'),
                    repo_name: repo.repo_name
                  })
        end
      end
    end
  end
end
