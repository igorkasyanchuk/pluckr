# frozen_string_literal: true

require "pluckr"
require_relative "support/database"
require_relative "support/sql_counter"
require_relative "support/sql_helpers"

TestDatabase.connect!

require_relative "support/models"
require_relative "support/query_helpers"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.include QueryHelpers
  config.include SqlHelpers
  config.order = :random
  Kernel.srand config.seed

  config.before(:suite) { TestDatabase.truncate! }
  config.after { TestDatabase.truncate! }
end
