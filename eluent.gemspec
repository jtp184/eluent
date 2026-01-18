# frozen_string_literal: true

require_relative 'lib/eluent/version'

Gem::Specification.new do |spec|
  spec.name = 'eluent'
  spec.version = Eluent::VERSION
  spec.authors = ['Justin Piotroski']
  spec.email = ['justin.piotroski@gmail.com']

  spec.summary = 'Molecular task tracking for human and synthetic workers.'
  spec.homepage = 'https://github.com/jtp184/eluent'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/jtp184/eluent'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # CLI interaction
  spec.add_dependency 'pastel', '~> 0.8'
  spec.add_dependency 'tty-box', '~> 0.7'
  spec.add_dependency 'tty-option', '~> 0.3'
  spec.add_dependency 'tty-prompt', '~> 0.23'
  spec.add_dependency 'tty-spinner', '~> 0.9'
  spec.add_dependency 'tty-table', '~> 0.12'
  spec.add_dependency 'tty-tree', '~> 0.4'

  # HTTP for AI integrations
  spec.add_dependency 'httpx', '~> 1.3'
end
