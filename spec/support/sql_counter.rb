# frozen_string_literal: true

# Counts real SQL statements executed inside a block, ignoring schema
# introspection, transactions and cached queries.
module SqlCounter
  IGNORED_NAMES = ["SCHEMA", "TRANSACTION", "CACHE"].freeze
  IGNORED_SQL = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|SET|SHOW)/i

  module_function

  def capture
    statements = []

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      payload = event.payload
      next if IGNORED_NAMES.include?(payload[:name])
      next if payload[:cached]
      next if payload[:sql].match?(IGNORED_SQL)

      statements << payload[:sql]
    end

    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
