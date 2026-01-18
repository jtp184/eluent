# frozen_string_literal: true

require 'yaml'

module Eluent
  module CLI
    module Commands
      # Configuration management
      class Config < BaseCommand
        GLOBAL_CONFIG_PATH = File.expand_path('~/.eluent/config.yaml')

        usage do
          program 'el config'
          desc 'Manage configuration'
          example 'el config show', 'Show current configuration'
          example 'el config get defaults.priority', 'Get a specific value'
          example 'el config set defaults.priority 1', 'Set a value'
        end

        argument :action do
          optional
          desc 'Action: show, get, set'
        end

        argument :key do
          optional
          desc 'Configuration key (dot notation)'
        end

        argument :value do
          optional
          desc 'Value to set'
        end

        flag :global do
          short '-g'
          long '--global'
          desc 'Use global config (~/.eluent/config.yaml)'
        end

        flag :local do
          short '-l'
          long '--local'
          desc 'Use local config (.eluent/config.yaml)'
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

          action = params[:action] || 'show'

          case action
          when 'show'
            show_config
          when 'get'
            get_config
          when 'set'
            set_config
          else
            error('INVALID_REQUEST', "Unknown action: #{action}")
          end
        end

        private

        def config_path
          if params[:global]
            GLOBAL_CONFIG_PATH
          else
            ensure_initialized!
            File.join(Dir.pwd, '.eluent', 'config.yaml')
          end
        end

        def load_config
          return {} unless File.exist?(config_path)

          YAML.safe_load_file(config_path) || {}
        end

        def save_config(config)
          FileUtils.mkdir_p(File.dirname(config_path))
          File.write(config_path, YAML.dump(config))
        end

        def show_config
          config = load_config

          if @robot_mode
            puts JSON.generate({
                                 status: 'ok',
                                 data: {
                                   path: config_path,
                                   config: config
                                 }
                               })
          else
            puts @pastel.bold("Configuration: #{config_path}")
            puts
            if config.empty?
              puts @pastel.dim('(empty)')
            else
              puts YAML.dump(config)
            end
          end

          0
        end

        def get_config
          key = params[:key]

          return error('INVALID_REQUEST', 'key is required for get') unless key

          config = load_config
          value = dig_value(config, key)

          if @robot_mode
            puts JSON.generate({
                                 status: 'ok',
                                 data: {
                                   key: key,
                                   value: value
                                 }
                               })
          elsif value.nil?
            puts @pastel.dim('(not set)')
          else
            puts value.is_a?(Hash) ? YAML.dump(value) : value
          end

          0
        end

        def set_config
          key = params[:key]
          value = params[:value]

          return error('INVALID_REQUEST', 'key is required for set') unless key

          return error('INVALID_REQUEST', 'value is required for set') unless value

          # Parse value
          parsed_value = parse_value(value)

          config = load_config
          set_value(config, key, parsed_value)
          save_config(config)

          success("Set #{key} = #{parsed_value}", data: {
                    key: key,
                    value: parsed_value
                  })
        end

        def dig_value(hash, key)
          keys = key.split('.')
          keys.reduce(hash) do |h, k|
            return nil unless h.is_a?(Hash)

            h[k]
          end
        end

        def set_value(hash, key, value)
          keys = key.split('.')
          last_key = keys.pop

          target = keys.reduce(hash) do |h, k|
            h[k] ||= {}
            h[k]
          end

          target[last_key] = value
        end

        def parse_value(value)
          case value
          when 'true' then true
          when 'false' then false
          when 'null', 'nil' then nil
          when /\A\d+\z/ then value.to_i
          when /\A\d+\.\d+\z/ then value.to_f
          else value
          end
        end
      end
    end
  end
end
