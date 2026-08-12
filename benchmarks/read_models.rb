# frozen_string_literal: true

# Compares Pluckr against hand-written ActiveRecord for the same read models.
#
#   bundle exec ruby benchmarks/read_models.rb            # PostgreSQL (default)
#   DB=sqlite bundle exec ruby benchmarks/read_models.rb  # SQLite, in memory
#
# Knobs: USERS (dataset size), PAGES (comma-separated page sizes), RUNS (samples).

# PostgreSQL unless told otherwise: the numbers are meant to resemble production.
ENV["DB"] ||= "postgres"

require "pluckr"
require "./spec/support/database"

TestDatabase.connect!

require "./spec/support/models"
require "./spec/support/sql_counter"

USERS = Integer(ENV.fetch("USERS", 50_000))
PAGES = ENV.fetch("PAGES", "10,100,1000,10000").split(",").map { |value| Integer(value) }
RUNS  = Integer(ENV.fetch("RUNS", 25))

# The N+1 variant issues 4 statements per row, so it gets fewer samples on the
# big pages. Everything else keeps the full sample count.
def runs_for(page, naive: false)
  return 1 if naive && page >= 10_000
  return [RUNS, 3].min if naive && page >= 1_000
  return [RUNS, 5].min if page >= 1_000

  RUNS
end

# ----------------------------------------------------------------- read models

class UserSummary < Pluckr::Query
  source User

  schema do
    field :id
    field :email

    one :subscription do
      field :name

      one :plan do
        field :name
      end
    end

    exists :photos
    count :videos
  end
end

# A wider, more realistic card: aliases, two singular associations (one of them
# self-referential), an existence check and four aggregates - two of them scoped.
class UserCard < Pluckr::Query
  source User

  schema do
    field :id
    field :email, as: :contact
    field :created_at, as: :joined_at

    one :subscription do
      field :name

      one :plan do
        field :name
      end
    end

    one :manager do
      field :email
    end

    exists :photos, as: :has_photos
    count :videos, as: :video_count
    count :videos, as: :big_video_count, scope: ->(rel) { rel.where(size: 200..) }
    count :comments, as: :comment_count
    count :orders, as: :paid_orders, where: { status: "paid" }
    sum :orders, column: :amount, as: :lifetime_value, where: { status: "paid" }
  end
end

class DashboardStats < Pluckr::Query
  schema do
    count :users, from: User
    count :comments, from: Comment
    count :active_accounts, from: Account, where: { active: true }
  end
end

# ------------------------------------------------------------------- the seed

def seed!
  TestDatabase.truncate!
  now = Time.now.utc

  plans = (1..5).map { |i| { name: "plan-#{i}", price: i * 10 } }
  Plan.insert_all(plans)
  plan_ids = Plan.order(:id).pluck(:id)

  (1..USERS).each_slice(1_000) do |ids|
    User.insert_all(ids.map do |i|
      { id: i, email: "user#{i}@example.com", active: i.even?, created_at: now, updated_at: now }
    end)

    Subscription.insert_all(ids.select { |i| i % 10 < 7 }.map do |i|
      { id: i, user_id: i, plan_id: plan_ids[i % plan_ids.size], name: "sub-#{i}" }
    end)

    Photo.insert_all(ids.select { |i| i % 10 < 6 }.flat_map do |i|
      2.times.map { |n| { user_id: i, url: "https://example.com/#{i}-#{n}.jpg" } }
    end)

    Video.insert_all(ids.select { |i| i % 2 == 1 }.flat_map do |i|
      3.times.map { |n| { user_id: i, size: 100 + n } }
    end)

    Comment.insert_all(ids.map { |i| { user_id: i, body: "c-#{i}" } })

    Order.insert_all(ids.flat_map do |i|
      2.times.map { |n| { user_id: i, status: n.zero? ? "paid" : "pending", amount: 10 + (i % 90) } }
    end)
  end

  # Half the users report to the user before them, so `one :manager` has work.
  User.where("id % 2 = 0").update_all("manager_id = id - 1")
  Account.insert_all((1..2_000).map { |i| { active: i % 3 == 0 } })

  ActiveRecord::Base.connection.execute("ANALYZE") if TestDatabase::ADAPTER != "mysql"
end

# ------------------------------------------------------------ the alternatives

# What most code does: load the record, then ask it questions.
def ar_naive_single(id)
  user = User.find(id)

  {
    id: user.id,
    email: user.email,
    subscription: user.subscription&.name,
    plan: user.subscription&.plan&.name,
    photos_exists: user.photos.exists?,
    videos_count: user.videos.count
  }
end

def pluckr_single(id)
  UserSummary.find(id).to_h
end

# A tuned hand-written version: preloads + grouped aggregates, no N+1.
def ar_tuned_list(page)
  users = User.where(active: true).order(:id).limit(page).includes(subscription: :plan).to_a
  ids = users.map(&:id)

  with_photos = Photo.where(user_id: ids).distinct.pluck(:user_id).to_set
  video_counts = Video.where(user_id: ids).group(:user_id).count

  users.map do |user|
    {
      id: user.id,
      email: user.email,
      subscription: user.subscription&.name,
      plan: user.subscription&.plan&.name,
      photos_exists: with_photos.include?(user.id),
      videos_count: video_counts.fetch(user.id, 0)
    }
  end
end

# The same list with an N+1, which is what a preload-less controller produces.
def ar_naive_list(page)
  User.where(active: true).order(:id).limit(page).map { |user| ar_naive_single(user.id) }
end

def pluckr_list(page)
  UserSummary.where(active: true).order(:id).limit(page).fetch.map(&:to_h)
end

# The same card, hand-written: preloads plus one grouped query per aggregate.
def ar_tuned_card(page)
  users = User.where(active: true).order(:id).limit(page).includes(:manager, subscription: :plan).to_a
  ids = users.map(&:id)

  with_photos = Photo.where(user_id: ids).distinct.pluck(:user_id).to_set
  video_counts = Video.where(user_id: ids).group(:user_id).count
  big_video_counts = Video.where(user_id: ids).where(size: 200..).group(:user_id).count
  comment_counts = Comment.where(user_id: ids).group(:user_id).count
  paid = Order.where(user_id: ids, status: "paid").group(:user_id)
  paid_counts = paid.count
  paid_totals = paid.sum(:amount)

  users.map do |user|
    {
      id: user.id,
      contact: user.email,
      joined_at: user.created_at,
      subscription: user.subscription&.name,
      plan: user.subscription&.plan&.name,
      manager: user.manager&.email,
      has_photos: with_photos.include?(user.id),
      video_count: video_counts.fetch(user.id, 0),
      big_video_count: big_video_counts.fetch(user.id, 0),
      comment_count: comment_counts.fetch(user.id, 0),
      paid_orders: paid_counts.fetch(user.id, 0),
      lifetime_value: paid_totals[user.id]
    }
  end
end

def ar_naive_card(page)
  User.where(active: true).order(:id).limit(page).map do |user|
    {
      id: user.id,
      contact: user.email,
      joined_at: user.created_at,
      subscription: user.subscription&.name,
      plan: user.subscription&.plan&.name,
      manager: user.manager&.email,
      has_photos: user.photos.exists?,
      video_count: user.videos.count,
      big_video_count: user.videos.where(size: 200..).count,
      comment_count: user.comments.count,
      paid_orders: user.orders.where(status: "paid").count,
      lifetime_value: user.orders.where(status: "paid").sum(:amount)
    }
  end
end

def pluckr_card(page)
  UserCard.where(active: true).order(:id).limit(page).fetch.map(&:to_h)
end

def ar_dashboard
  { users: User.count, comments: Comment.count, active_accounts: Account.where(active: true).count }
end

def pluckr_dashboard
  DashboardStats.fetch.to_h
end

# ------------------------------------------------------------------ the ruler

Result = Struct.new(:label, :rows, :statements, :median_ms, :allocations, :factor, keyword_init: true)

def measure(label, rows: nil, runs: RUNS)
  yield # warm up the connection, the query cache and any lazy AR machinery

  statements = SqlCounter.capture { yield }.size

  before = GC.stat(:total_allocated_objects)
  yield
  allocations = GC.stat(:total_allocated_objects) - before

  timings = Array.new(runs) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
  end.sort

  Result.new(label: label, rows: rows, statements: statements,
             median_ms: timings[runs / 2], allocations: allocations)
end

HEADER = format("  %-36s %7s %8s %12s %14s %11s",
                "", "rows", "SQL", "median ms", "allocations", "vs Pluckr")

# Each group is compared against its own Pluckr row.
def rows_for(results)
  baseline = results.reverse.find { |result| result.label.start_with?("Pluckr") }
  results.each { |result| result.factor = result.median_ms / baseline.median_ms }
  results
end

def print_rows(results)
  rows_for(results).each do |result|
    puts format("  %-36s %7s %8d %12.3f %14d %10.1fx",
                result.label, result.rows || "1", result.statements,
                result.median_ms, result.allocations, result.factor)
  end
end

# ------------------------------------------------------------------ the plans

# EXPLAIN ANALYZE for the statements Pluckr generates, plus the ActiveRecord
# query they replace. PostgreSQL only; set EXPLAIN=0 to skip.
def explain!(label, sql)
  plan = ActiveRecord::Base.connection.select_all("EXPLAIN (ANALYZE, BUFFERS) #{sql}").rows.flatten

  puts "\n### #{label}\n\n#{sql}\n"
  puts plan.map { |line| "  #{line}" }
end

def explain_all!(id)
  return unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"
  return if ENV["EXPLAIN"] == "0"

  puts "\n" + ("=" * 78) + "\nEXPLAIN ANALYZE\n" + ("=" * 78)

  explain!("Pluckr, single record", UserSummary.where(id: id).limit(1).to_sql)
  explain!("Pluckr, list of #{PAGES.first}",
           UserSummary.where(active: true).order(:id).limit(PAGES.first).to_sql)
  explain!("ActiveRecord, the list query it replaces",
           User.where(active: true).order(:id).limit(PAGES.first).to_sql)
  page_ids = User.where(active: true).order(:id).limit(PAGES.first).pluck(:id)
  explain!("ActiveRecord, the grouped count that goes with it",
           Video.where(user_id: page_ids).group(:user_id).select(:user_id, "COUNT(*)").to_sql)
  explain!("Pluckr, wide card, list of #{PAGES.first}",
           UserCard.where(active: true).order(:id).limit(PAGES.first).to_sql)
  explain!("Pluckr, dashboard", DashboardStats.to_sql)
end

# ------------------------------------------------------------------ the run

puts "adapter: #{ActiveRecord::Base.connection.adapter_name}  users: #{USERS}  " \
     "pages: #{PAGES.join(", ")}  runs: #{RUNS}"
print "seeding... "
seed!
puts "done"

id = USERS / 2

puts "\nSingle record: id, email, subscription.name, subscription.plan.name, photos?, videos count"
puts HEADER
print_rows([
             measure("ActiveRecord, record + questions") { ar_naive_single(id) },
             measure("Pluckr") { pluckr_single(id) }
           ])

puts "\nLists of the same shape"
puts HEADER
PAGES.each do |page|
  print_rows([
               measure("ActiveRecord, N+1", rows: page, runs: runs_for(page, naive: true)) do
                 ar_naive_list(page)
               end,
               measure("ActiveRecord, preloaded + grouped", rows: page, runs: runs_for(page)) do
                 ar_tuned_list(page)
               end,
               measure("Pluckr", rows: page, runs: runs_for(page)) { pluckr_list(page) }
             ])
  puts
end

puts "Wide card: 3 fields, 2 nested associations, exists, 3 counts, 1 sum"
puts HEADER
PAGES.each do |page|
  print_rows([
               measure("ActiveRecord, N+1", rows: page, runs: runs_for(page, naive: true)) do
                 ar_naive_card(page)
               end,
               measure("ActiveRecord, preloaded + grouped", rows: page, runs: runs_for(page)) do
                 ar_tuned_card(page)
               end,
               measure("Pluckr", rows: page, runs: runs_for(page)) { pluckr_card(page) }
             ])
  puts
end

puts "Dashboard: 3 independent counts"
puts HEADER
print_rows([
             measure("ActiveRecord, three counts") { ar_dashboard },
             measure("Pluckr") { pluckr_dashboard }
           ])

explain_all!(id)

# Sanity: the alternatives must agree, or the numbers mean nothing.
raise "single mismatch" unless ar_naive_single(id).values_at(:id, :videos_count) ==
                              pluckr_single(id).values_at(:id, :videos_count)
raise "list mismatch" unless ar_tuned_list(100).map { |r| r[:id] } == pluckr_list(100).map { |r| r[:id] }
raise "dashboard mismatch" unless ar_dashboard == pluckr_dashboard
raise "card mismatch" unless ar_tuned_card(50) == ar_naive_card(50)
raise "card mismatch" unless ar_tuned_card(50) == pluckr_card(50).map { |row|
  row.merge(subscription: row[:subscription]&.fetch(:name), plan: row.dig(:subscription, :plan, :name),
            manager: row[:manager]&.fetch(:email))
}.map { |row| row.slice(*ar_tuned_card(1).first.keys) }

puts "\nresults verified identical across all three implementations"

# KEEP=1 leaves the seeded data behind for poking at it with psql.
TestDatabase.truncate! unless ENV["KEEP"] == "1"
