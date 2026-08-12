# frozen_string_literal: true

# Builds expected SQL fragments with the current adapter's quoting, so the same
# assertions hold on PostgreSQL, MySQL and SQLite.
module SqlHelpers
  def connection
    ActiveRecord::Base.connection
  end

  def q(name)
    connection.quote_column_name(name.to_s)
  end

  def qt(name)
    connection.quote_table_name(name.to_s)
  end

  def col(table, column)
    "#{qt(table)}.#{q(column)}"
  end

  def qv(value)
    connection.quote(value)
  end

  # SQLite renders `"photos" AS "alias"`, PostgreSQL/MySQL render `"photos" "alias"`.
  def aliased_table(table, alias_name)
    connection.visitor.compile(Arel::Table.new(table).alias(alias_name))
  end

  def adapter
    connection.adapter_name.downcase
  end
end
