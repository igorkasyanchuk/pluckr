# frozen_string_literal: true

# Conveniences available in bin/console.
module Kernel
  # Print the SQL a query or relation compiles to, broken across lines.
  def sql(query)
    puts query.to_sql.gsub(/ (FROM|LEFT OUTER JOIN|INNER JOIN|WHERE|GROUP BY|ORDER BY|LIMIT|OFFSET) /,
                           "\n\\1 ")
    nil
  end

  # EXPLAIN it, in whatever form the connected adapter understands.
  def explain(query, analyze: false)
    prefix =
      case Dev.connection.adapter_name
      when "PostgreSQL" then analyze ? "EXPLAIN (ANALYZE, BUFFERS)" : "EXPLAIN"
      when "SQLite" then "EXPLAIN QUERY PLAN"       # plain EXPLAIN dumps bytecode
      else "EXPLAIN"
      end

    puts Dev.connection.select_all("#{prefix} #{query.to_sql}").rows.map { |row| row.join("  ") }
    nil
  end

  # Print every statement a block executes and return how many there were.
  def statements
    executed = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      next if %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached]

      executed << payload[:sql]
    end

    yield
    executed.each_with_index { |statement, i| puts "#{i + 1}. #{statement}" }
    executed.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def reseed!(users: 20)
    Dev.seed!(users: users)
  end

  def reset!
    Dev.reset!
    Dev.seed!
  end
end
