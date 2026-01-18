# frozen_string_literal: true

$VERBOSE = nil

require 'eluent'
require 'webmock/rspec'

# Load support files
Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Run specs in random order for better isolation
  config.order = :random

  # Seed global randomization to allow reproduction of test order
  Kernel.srand config.seed

  # Filter examples by focus tags
  config.filter_run_when_matching :focus

  # Disable real HTTP connections
  WebMock.disable_net_connect!(allow_localhost: true)
end
