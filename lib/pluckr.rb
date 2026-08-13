# frozen_string_literal: true

require "active_record"
require "active_support/core_ext/object/json"
require "active_support/notifications"

require "pluckr/version"
require "pluckr/errors"
require "pluckr/aliases"
require "pluckr/reflection/association"
require "pluckr/schema/node"
require "pluckr/schema/conditions"
require "pluckr/schema/field"
require "pluckr/schema/one"
require "pluckr/schema/exists"
require "pluckr/schema/aggregate"
require "pluckr/schema/scope"
require "pluckr/schema/definition"
require "pluckr/compiler/sql"
require "pluckr/result/object"
require "pluckr/result/builder"
require "pluckr/relation"
require "pluckr/batch"
require "pluckr/query"

# A declarative read-query layer for ActiveRecord.
#
#   DSL -> schema AST -> reflection -> SQL compiler -> flat row -> result object
module Pluckr
  # Every read of a read model goes through here, so one subscription covers
  # `fetch`, `find`, `for` and `Pluckr.batch` alike. The statements Pluckr does
  # not compile are absent by design: `count`/`exists?` and the primary keys of
  # a paginated `.for` are ActiveRecord's own, and arrive as `sql.active_record`.
  #
  #   ActiveSupport::Notifications.subscribe("fetch.pluckr") do |*, payload|
  #     payload[:name]  # => "UserSummary"
  #     payload[:sql]   # => "SELECT ..."
  #     payload[:rows]  # => 100
  #   end
  def self.select_all(connection, sql, name:, label: "#{name} Pluckr")
    ActiveSupport::Notifications.instrument("fetch.pluckr", name: name, sql: sql) do |payload|
      connection.select_all(sql, label).tap { |result| payload[:rows] = result.length }
    end
  end
end
