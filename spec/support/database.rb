# frozen_string_literal: true

require "active_record"

# Test database setup. Pick the backend with DB=sqlite|postgres|mysql,
# defaulting to an in-memory SQLite database so the suite runs anywhere.
module TestDatabase
  ADAPTER = ENV.fetch("DB", "sqlite")
  DATABASE = ENV.fetch("PLUCKR_TEST_DATABASE", "pluckr_test")

  CONFIGS = {
    "sqlite" => { adapter: "sqlite3", database: ":memory:" },
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
    CONFIGS.fetch(ADAPTER) { raise ArgumentError, "unknown DB=#{ADAPTER}" }
  end

  def connect!
    create_database! unless ADAPTER == "sqlite"
    ActiveRecord::Base.establish_connection(config)
    load_schema!
  end

  def create_database!
    ActiveRecord::Base.establish_connection(config.merge(database: bootstrap_database))
    ActiveRecord::Base.connection.create_database(DATABASE)
  rescue ActiveRecord::DatabaseAlreadyExists, ActiveRecord::StatementInvalid
    nil
  ensure
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  # A database that always exists, used only to CREATE the test database.
  def bootstrap_database
    ADAPTER == "postgres" ? "postgres" : "mysql"
  end

  def load_schema!
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :users, force: true do |t|
        t.string :email
        t.boolean :active, default: true, null: false
        t.bigint :manager_id           # self-referential association
        t.string :region_code          # points at a non-`id` primary key
        t.timestamps
      end
      add_index :users, :email, unique: true
      add_index :users, %i[active id]   # the paged list query
      add_index :users, :created_at
      add_index :users, :manager_id
      add_index :users, :region_code

      # Custom (string) primary key.
      create_table :regions, primary_key: :code, id: :string, force: true do |t|
        t.string :title
      end

      # Custom table name.
      create_table :legacy_invoices, force: true do |t|
        t.references :user
        t.integer :cents
      end

      # Single table inheritance.
      create_table :documents, force: true do |t|
        t.references :user, index: false
        t.string :type
        t.string :title
      end
      add_index :documents, %i[user_id type] # STI lookups carry the type

      create_table :plans, force: true do |t|
        t.references :vendor
        t.string :name
        t.integer :price
      end

      create_table :vendors, force: true do |t|
        t.string :name
      end

      create_table :subscriptions, force: true do |t|
        t.references :user, index: { unique: true } # has_one
        t.references :plan
        t.string :name
      end

      # Custom foreign key on both sides of a singular association.
      create_table :profiles, force: true do |t|
        t.bigint :owner_id, index: { unique: true } # has_one with a custom key
        t.string :nickname
      end

      create_table :photos, force: true do |t|
        t.references :user
        t.string :url
      end

      create_table :videos, force: true do |t|
        t.references :user
        t.integer :size
      end
      add_index :videos, %i[user_id size] # filtered counts

      create_table :comments, force: true do |t|
        t.references :user
        t.string :body
      end

      create_table :accounts, force: true do |t|
        t.boolean :active, default: false, null: false
      end
      add_index :accounts, :active

      # Polymorphic association target.
      create_table :likes, force: true do |t|
        t.bigint :likeable_id
        t.string :likeable_type
      end
      add_index :likes, %i[likeable_type likeable_id]

      create_table :orders, force: true do |t|
        t.string :status
        t.integer :amount
      end
      add_index :orders, %i[status amount]
    end
  end

  # DELETE works on every adapter and the test schema has no foreign keys.
  def truncate!
    connection = ActiveRecord::Base.connection
    (connection.tables - %w[schema_migrations ar_internal_metadata]).each do |table|
      connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
    end
  end
end
