# Pluckr

A declarative read-query layer for ActiveRecord.

Declare the data a screen or endpoint needs, get one SQL statement and a plain
Ruby object back. No ActiveRecord models are instantiated.

```ruby
user.id
user.email
user.subscription.name   # +1 query
user.photos.exists?      # +1 query
user.videos.count        # +1 query
```

becomes:

```ruby
class UserSummary < Pluckr::Query
  source User

  schema do
    field :id
    field :email

    one :subscription do
      field :id
      field :name
    end

    exists :photos
    count :videos
  end
end

user = UserSummary.find(1)

user.id             # => 1
user.email          # => "user@example.com"
user.subscription   # => #<UserSummary.subscription id=5, name="Pro"> (nil if none)
user.photos_exists  # => true
user.videos_count   # => 2
user.to_h           # => {id: 1, email: "...", subscription: {...}, photos_exists: true, videos_count: 2}
```

One statement, exactly as `UserSummary.to_sql` prints it:

```sql
SELECT "users"."id"                    AS "id",
       "users"."email"                 AS "email",
       "pluckr_subscription"."id"      AS "__pluckr.subscription.present",
       "pluckr_subscription"."id"      AS "subscription.id",
       "pluckr_subscription"."name"    AS "subscription.name",
       EXISTS (SELECT 1 FROM "photos" "pluckr_sub_1"
                WHERE "pluckr_sub_1"."user_id" = "users"."id"
                LIMIT 1 OFFSET 0)      AS "photos_exists",
       (SELECT COUNT(*) FROM "videos" "pluckr_sub_2"
         WHERE "pluckr_sub_2"."user_id" = "users"."id") AS "videos_count"
  FROM "users"
  LEFT OUTER JOIN "subscriptions" "pluckr_subscription"
    ON "pluckr_subscription"."user_id" = "users"."id"
```

## Is it worth it?

PostgreSQL, 50k users, one page of this exact read model
([full results](BENCHMARKS.md)):

| rows | ActiveRecord, N+1 | ActiveRecord, preloaded + grouped | Pluckr |
| ---: | ---: | ---: | ---: |
| 10 | 49 SQL / 4.96 ms | 5 SQL / 0.76 ms | **1 SQL / 0.34 ms** |
| 100 | 481 SQL / 48.3 ms | 5 SQL / 2.83 ms | **1 SQL / 0.97 ms** |
| 1,000 | 4,801 SQL / 491 ms | 5 SQL / 23.2 ms | **1 SQL / 12.2 ms** |
| 10,000 | 48,001 SQL / 5,410 ms | 5 SQL / 287 ms | **1 SQL / 98.4 ms** |

2-3x faster than careful hand-written ActiveRecord, 15-55x faster than a
forgotten preload, and the gap grows with every millisecond of network latency
between the app and the database, because Pluckr always sends one statement.

## Install

```ruby
gem "pluckr"
```

Ruby 3.2+, ActiveRecord 7.1+. Tested on PostgreSQL, MySQL and SQLite.

## Querying

```ruby
UserSummary.find(1)                # one result object, raises ActiveRecord::RecordNotFound
UserSummary.fetch                  # array of result objects
UserSummary.where(active: true)
           .order(created_at: :desc)
           .limit(50)
           .offset(100)
           .fetch
UserSummary.where(active: true).to_sql
```

`where`/`where.not`/`order`/`limit`/`offset` are ActiveRecord's own - Pluckr
passes them through to the root relation and adds its projections on top. Every
chain is immutable, nothing runs until `fetch`/`find`/`first`, and every
execution is exactly one statement no matter how many nodes the schema has.

## Dashboards

Queries without a `source` are aggregate-only and return a single object:

```ruby
class DashboardStats < Pluckr::Query
  schema do
    count :users,    from: User
    count :comments, from: Comment
    count :active_accounts, from: Account, where: { active: true }

    sum :paid_revenue, from: Order, column: :amount, where: { status: "paid" }
    max :last_signup,  from: User,  column: :created_at
  end
end

stats = DashboardStats.fetch
stats.users            # => 1520
stats.active_accounts  # => 904
stats.to_h             # => {users: 1520, comments: 48203, ...}
```

```sql
SELECT (SELECT COUNT(*) FROM "users") AS "users",
       (SELECT COUNT(*) FROM "comments") AS "comments",
       (SELECT COUNT(*) FROM "accounts" WHERE "accounts"."active" = TRUE) AS "active_accounts"
```

One round trip. `where:` values go through ActiveRecord quoting.

## DSL

| Node | Result | SQL |
| --- | --- | --- |
| `field :email` | `email` | selected column |
| `field :email, as: :contact` | `contact` | selected column |
| `one :subscription do ... end` | `subscription` (or `nil`) | `LEFT OUTER JOIN` |
| `one :plan, via: :subscription do ... end` | `plan` | `LEFT OUTER JOIN` |
| `exists :photos` | `photos_exists` | correlated `EXISTS`, index probe per row |
| `exists :photos, as: :has_photos` | `has_photos` | correlated `EXISTS` |
| `count :videos` | `videos_count` | scalar subquery |
| `count :videos, as: :n_videos` | `n_videos` | scalar subquery |
| `count :users, from: User` | `users` | scalar subquery |
| `sum/min/max ..., column: :amount` | `<name>_sum` etc. | scalar subquery |

`exists`, `count`, `sum`, `min` and `max` all take `where:` and `scope:`:

```ruby
count :active_accounts, from: Account, where: { active: true }
count :active_accounts, from: Account, scope: ->(rel) { rel.active }

count  :big_videos, via: :videos, scope: ->(rel) { rel.where(size: 100..) }
exists :recent_photos, via: :photos, scope: -> { Photo.where(created_at: 1.week.ago..) }
```

`scope:` receives the target model's relation (or nothing, if the callable takes
no arguments) and must return a relation for the same model. It runs on every
compilation, so runtime values stay fresh. `where:` takes a plain hash.

A scope narrows rows only: `limit`/`offset`/`group` inside one raise, since the
subquery has to return exactly one value.

Scoped correlated nodes read through a derived table, so a scope may join (or
be) the very table it correlates to without capturing the correlation:

```ruby
count :active_photos, via: :photos, scope: ->(rel) { rel.joins(:user).where(users: { active: true }) }
count :active_reports, via: :direct_reports, scope: ->(rel) { rel.where(active: true) }
```

```sql
(SELECT COUNT(*)
   FROM (SELECT "photos".* FROM "photos"
           INNER JOIN "users" ON "users"."id" = "photos"."user_id"
          WHERE "users"."active" = TRUE) "pluckr_sub_1"
  WHERE "pluckr_sub_1"."user_id" = "users"."id")
```

`one` nests to any depth of singular associations:

```ruby
one :subscription do
  field :name

  one :plan do
    field :name
  end
end

user.subscription.plan.name
```

Foreign keys, primary keys and join direction come from ActiveRecord
reflection: `belongs_to`, `has_one`, custom `foreign_key:`/`primary_key:`,
`self.table_name`, self-referential associations, polymorphic `as:` targets and
STI type conditions all work without extra configuration.

`has_many` collections are never joined: `exists` and `count` compile to
correlated subqueries, so root rows are never multiplied and no `GROUP BY` is
needed. The `LIMIT 1 OFFSET 0` on `EXISTS` is an optimisation fence - without it
PostgreSQL rewrites the subquery into a full scan of the child table, which
costs 50x on a paged query. [BENCHMARKS.md](BENCHMARKS.md#why-exists-carries-limit-1-offset-0)
has the measurements.

### Missing vs NULL

Pluckr selects the association's primary key as a hidden presence marker, so
these stay distinct:

```ruby
user.subscription        # => nil                  no subscription row
user.subscription.name   # => nil                  row exists, name is NULL
```

## Result objects

Frozen, ActiveRecord-free, one reader per declared output:

```ruby
user.class.ancestors.include?(ActiveRecord::Base) # => false
user.frozen?                                      # => true
user[:email]
user.to_h          # nested, internal aliases stripped
user.created_at    # NoMethodError - not selected
```

Values are cast with the model's own column types, so `active` is `true` and
not `1` on every adapter.

## Errors, early

Schema mistakes raise at class-definition time, not on the first request:

```ruby
field :does_not_exist  # Pluckr::UnknownField: User does not have column `does_not_exist`
one :unknown           # Pluckr::UnknownAssociation: User does not have association `unknown`
one :photos            # Pluckr::InvalidAssociation: `User#photos` is a has_many association
                       #   and cannot be used with `one`
field :id              # Pluckr::MissingSource (no `source` declared)
schema { }             # Pluckr::ConfigurationError: `schema` block is empty
count :x, scope: {}    # Pluckr::ConfigurationError: `scope:` expects a callable
```

The rest raise on first compilation, where the context exists to detect them: a
`scope:` returning the wrong model, `limit`/`offset`/`group` inside a scope, and
output aliases longer than the database's identifier limit.

## How it works

```
DSL -> schema AST -> reflection -> SQL compiler -> flat row -> result object
```

| File | Job |
| --- | --- |
| `schema/definition.rb` | evaluates the DSL, validates, builds the AST |
| `reflection/association.rb` | the only place that touches AR reflection |
| `compiler/sql.rb` | AST + Arel -> one SQL statement |
| `relation.rb` | chaining, delegates root filtering to AR |
| `result/builder.rb` | flat row -> nested frozen objects |

The compiler never sees DSL state, so new node types are additive.

## Not in v0.1

- `many` (nested collections)
- raw SQL fields, manual joins
- `has_many :through`, polymorphic `belongs_to`, associations with their own
  scope, and associations whose model has a `default_scope` (these raise
  `Pluckr::UnsupportedAssociation` rather than silently ignoring the scope).
  Polymorphic `has_many ..., as:` targets and STI children *are* supported.
- writes, serializers, pagination beyond `limit`/`offset`, caching

## What Pluckr is not

Not an ORM, not a serializer, not GraphQL, not a replacement for ActiveRecord.
Use it where loading full object graphs is wasted work: API read models, index
and admin tables, dashboards, reports, background-job payloads.

## Benchmarks

```bash
bundle exec ruby benchmarks/read_models.rb            # PostgreSQL
DB=sqlite bundle exec ruby benchmarks/read_models.rb  # SQLite
PAGES=25,250 USERS=200000 bundle exec ruby benchmarks/read_models.rb
```

The script seeds a dataset, runs the same read model as naive ActiveRecord,
hand-tuned ActiveRecord and Pluckr at four page sizes, verifies all three return
identical data, and prints `EXPLAIN ANALYZE` for the generated SQL.

[BENCHMARKS.md](BENCHMARKS.md) has the numbers for PostgreSQL and SQLite, the
query plans, how cost scales with page size, what a missing foreign key index
costs (123x), and what to expect once the database is a network hop away.

## Try it locally

No Rails app needed - the repository ships a sandbox with its own schema, seeds
and example read models.

```bash
git clone https://github.com/igorkasyanchuk/pluckr && cd pluckr
bundle install
bin/setup      # creates the dev database, loads the schema, seeds it
bin/console    # IRB with the models, seeds and example queries loaded
```

```
Pluckr 0.1.0 sandbox - sqlite3 dev/pluckr_dev.sqlite3
users: 21  subscriptions: 14  plans: 3  photos: 29  videos: 31  comments: 49

Queries:  UserSummary, UserCard, DashboardStats     (see dev/queries.rb)
Models:   User, Subscription, Plan, Photo, Video, Comment, Account, Order

>> UserSummary.find(2).to_h
=> {id: 2, email: "user1@example.com",
    subscription: {id: 1, name: "sub-1", plan: {name: "Pro", price_cents: 2900}},
    photos_exists: true, videos_count: 3}

>> statements { UserSummary.where(active: true).limit(5).fetch }
1. SELECT "users"."id" AS "id", ...
=> 1

>> DashboardStats.fetch.to_h
=> {users: 21, active_users: 16, comments: 49, active_accounts: 5,
    paid_revenue: 1641, last_signup: 2026-08-12 21:14:14 UTC}
```

The seed data is deliberately uneven - some users have no subscription, some
subscriptions have no plan - so `nil` versus NULL is visible immediately.

### Console helpers

| | |
| --- | --- |
| `sql(query)` | print the generated SQL, split across clauses |
| `explain(query)` | `EXPLAIN` it (`analyze: true` for `EXPLAIN ANALYZE` on PostgreSQL) |
| `statements { ... }` | print and count the statements a block executes |
| `reseed!(users: 500)` | wipe and re-seed |
| `reset!` | reload the schema, then re-seed |
| `Dev.log!` | echo every statement to stdout |
| `Dev.counts` | row counts per table |

### What is in `dev/`

| File | Contents |
| --- | --- |
| `dev/schema.rb` | users, subscriptions, plans, photos, videos, comments, accounts, orders - with the indexes a real app would have |
| `dev/models.rb` | the ActiveRecord models, including a self-referential `manager` / `direct_reports` |
| `dev/seeds.rb` | deterministic seed data |
| `dev/queries.rb` | `UserSummary`, `UserCard`, `DashboardStats` - aliases, nesting, `via:`, `where:`, `scope:`, dashboards |
| `dev/console_helpers.rb` | the helpers above |
| `dev/boot.rb` | connection, `Dev.reset!`, `Dev.seed!`, `Dev.log!` |

Edit `dev/queries.rb` and pick the changes up without leaving the session:

```ruby
>> load "dev/queries.rb"
>> sql UserSummary.limit(1)
```

### Another database

SQLite is the default and lives in `dev/pluckr_dev.sqlite3`, so the data
survives between sessions.

```bash
DB=postgres bin/setup && DB=postgres bin/console
DB=mysql    bin/setup && DB=mysql    bin/console
SEED_USERS=5000 DB=postgres bin/setup       # a dataset worth EXPLAIN-ing
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `DB` | `sqlite` | `sqlite`, `postgres` or `mysql` |
| `SEED_USERS` | `20` | how many users to seed |
| `PLUCKR_DEV_DATABASE` | `pluckr_dev` | database name (file name on SQLite) |
| `PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` | `postgres` user | PostgreSQL connection |
| `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` / `MYSQL_PASSWORD` | `root@127.0.0.1` | MySQL connection |

## Development

```bash
bundle exec rspec              # SQLite (default)
DB=postgres bundle exec rspec  # needs a running PostgreSQL
DB=mysql bundle exec rspec
```

The spec suite manages its own `pluckr_test` database and is independent of the
`dev/` sandbox. CI runs it on Ruby 3.2 and 3.4 against SQLite, PostgreSQL and
MySQL; changes should pass on SQLite and PostgreSQL locally before pushing.

Benchmarks live in `benchmarks/read_models.rb` - see
[Benchmarks](#benchmarks) above. [AGENTS.md](AGENTS.md) documents the internals,
the invariants and why the generated SQL looks the way it does.

## License

MIT.
