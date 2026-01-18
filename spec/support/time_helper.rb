# frozen_string_literal: true

require 'timecop'

# Helpers for time-dependent tests
module TimeHelper
  def freeze_at(time, &)
    Timecop.freeze(time, &)
  end

  def travel_to(time, &)
    Timecop.travel(time, &)
  end

  # Standard test times
  def fixed_time
    Time.utc(2025, 6, 15, 12, 0, 0)
  end

  def past_time
    Time.utc(2025, 6, 14, 12, 0, 0)
  end

  def future_time
    Time.utc(2025, 6, 16, 12, 0, 0)
  end
end

RSpec.configure do |config|
  config.include TimeHelper

  config.after do
    Timecop.return
  end
end
