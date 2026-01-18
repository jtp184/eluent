# frozen_string_literal: true

require 'fakefs/spec_helpers'

# Helpers for filesystem-based tests using FakeFS
module FilesystemHelper
  def setup_eluent_directory(root = '/project')
    FileUtils.mkdir_p(File.join(root, '.eluent'))
    FileUtils.touch(File.join(root, '.eluent', 'data.jsonl'))
    FileUtils.mkdir_p(File.join(root, '.git'))
    root
  end

  def setup_config_file(root = '/project', config = {})
    require 'yaml'
    config_path = File.join(root, '.eluent', 'config.yaml')
    File.write(config_path, YAML.dump(config))
    config_path
  end

  def write_jsonl_records(path, records)
    File.open(path, 'w') do |file|
      records.each { |record| file.puts(JSON.generate(record)) }
    end
  end

  def read_jsonl_records(path)
    return [] unless File.exist?(path)

    File.readlines(path).map { |line| JSON.parse(line, symbolize_names: true) }
  end
end

RSpec.configure do |config|
  config.include FilesystemHelper, :filesystem
  config.include FakeFS::SpecHelpers, :filesystem
end
