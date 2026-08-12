# frozen_string_literal: true

# Development sandbox: a small application-like schema, models, seeds and a few
# example queries, so the gem can be driven by hand.
#
#   bin/setup      create the database, load the schema, seed it
#   bin/console    IRB with all of this loaded
#
# Pick the backend with DB=sqlite (default, a file under dev/) or DB=postgres.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "pluckr"
require "logger"

module Dev
  ADAPTER = ENV.fetch("DB", "sqlite")
  ROOT = File.expand_path("..", __dir__)
  DATABASE = ENV.fetch("PLUCKR_DEV_DATABASE", "pluckr_dev")
  SQLITE_PATH = File.join(ROOT, "dev", "#{DATABASE}.sqlite3")

  CONFIGS = {
    "sqlite" => { adapter: "sqlite3", database: SQLITE_PATH },
    "postgres" => {
      adapter: "postgresql",
      host: ENV["PGHOST"],
      port: ENV["PGPORT"],
      username: ENV.fetch("PGUSER", "postgres"),
      password: ENV["PGPASSWORD"],
      database: DATABASE,
      encoding: "utf8"
    }.compact,
    "mysql" => {
      adapter: "trilogy",
      host: ENV.fetch("MYSQL_HOST", "127.0.0.1"),
      port: ENV.fetch("MYSQL_PORT", 3306).to_i,
      username: ENV.fetch("MYSQL_USER", "root"),
      password: ENV["MYSQL_PASSWORD"],
      database: DATABASE,
      encoding: "utf8mb4"
    }.compact
  }.freeze

  module_function

  def config
    CONFIGS.fetch(ADAPTER) { raise ArgumentError, "unknown DB=#{ADAPTER} (sqlite, postgres, mysql)" }
  end

  def connection
    ActiveRecord::Base.connection
  end

  def connect!
    ActiveRecord::Base.establish_connection(config)
    connection.verify!
    true
  rescue ActiveRecord::NoDatabaseError
    false
  end

  # Creates the database if the adapter needs it, then loads the schema.
  def reset!
    create_database! unless ADAPTER == "sqlite"
    ActiveRecord::Base.establish_connection(config)
    load_schema!
    load_queries!
    puts "schema loaded into #{describe}"
  end

  def create_database!
    ActiveRecord::Base.establish_connection(config.merge(database: ADAPTER == "postgres" ? "postgres" : "mysql"))
    ActiveRecord::Base.connection.create_database(DATABASE)
  rescue ActiveRecord::DatabaseAlreadyExists, ActiveRecord::StatementInvalid
    nil
  ensure
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  def ready?
    connect! && connection.table_exists?(:users)
  end

  def describe
    ADAPTER == "sqlite" ? "sqlite3 #{SQLITE_PATH}" : "#{ADAPTER} database #{DATABASE}"
  end

  def load_schema!
    require_relative "schema"
  end

  # Query classes validate their columns as they load, so they can only be
  # defined once the schema exists.
  def load_queries!
    require_relative "queries"
  end

  def seed!(users: Integer(ENV.fetch("SEED_USERS", 20)))
    require_relative "seeds"
    Seeds.run(users: users)
  end

  # Echo every statement to stdout - handy while poking at queries in the console.
  def log!(enabled = true)
    ActiveRecord::Base.logger = enabled ? Logger.new($stdout, formatter: ->(_, _, _, msg) { "#{msg}\n" }) : nil
    enabled
  end

  def counts
    [User, Subscription, Plan, Photo, Video, Comment, Account, Order]
      .to_h { |model| [model.table_name.to_sym, model.count] }
  end
end

Dev.connect!
require_relative "models"
Dev.load_queries! if Dev.ready?
