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
([full results](BENCHMARKS.md), including a wider card with two nested
associations and four aggregates):

| rows | ActiveRecord, N+1 | ActiveRecord, preloaded + grouped | Pluckr |
| ---: | ---: | ---: | ---: |
| 10 | 49 SQL / 4.95 ms | 5 SQL / 0.82 ms | **1 SQL / 0.35 ms** |
| 100 | 481 SQL / 49.0 ms | 5 SQL / 2.90 ms | **1 SQL / 0.99 ms** |
| 1,000 | 4,801 SQL / 493 ms | 5 SQL / 23.3 ms | **1 SQL / 11.7 ms** |
| 10,000 | 48,001 SQL / 4,872 ms | 5 SQL / 286 ms | **1 SQL / 98.5 ms** |

2-3x faster than careful hand-written ActiveRecord, 12-55x faster than a
forgotten preload, and the gap grows with every millisecond of network latency
between the app and the database, because Pluckr always sends one statement. It
also grows with the read model: a wider card costs ActiveRecord one more query
per aggregate and costs Pluckr nothing extra.

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
`first` orders by the primary key when the chain has no order of its own, like
ActiveRecord does.

Subclassing a query inherits its `source` and `schema`; the subclass can declare
its own `schema` to replace them.

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

## Ad-hoc aggregates

`Pluckr::Query` is for read models you define once and reuse. When the
aggregates are decided at runtime - a detail page, a per-user summary, filters
from params - `Pluckr.batch` takes relations you already have and answers them
all in one statement:

```ruby
stats = Pluckr.batch do |b|
  b.count  user.videos,                          as: :video_count
  b.sum    user.videos.where(size: 100..), :size, as: :big_video_bytes
  b.avg    user.videos, :size,                    as: :average_size
  b.exists user.photos,                          as: :has_photos
  b.count  Account.active,                       as: :active_accounts
end

stats.video_count      # => 3
stats.has_photos       # => true
stats.to_h             # => {video_count: 3, big_video_bytes: 4200, ...}
```

```sql
SELECT (SELECT COUNT(*) FROM (SELECT "videos".* FROM "videos"
                               WHERE "videos"."user_id" = 1) "pluckr_batch_1") AS "video_count",
       ...
```

Each entry is the SQL **ActiveRecord already built**, wrapped in a derived
table. Whatever was applied to the relation stays applied: `default_scope`,
association scopes, `has_many :through`, polymorphic and STI conditions,
`joins`, `merge`, `distinct`, `group`, `limit`. The associations the schema DSL
refuses to compile all work here, because Pluckr is not deriving the join - it
is reading the relation's own `to_sql`.

A grouped relation returns one row per group, so only `count` and `exists` are
meaningful over it; asking for a `sum` of groups raises rather than guessing.

`count`, `sum`, `avg` (alias `average`), `min`, `max` and `exists` are
available; `as:` is always required. A model class works where a relation does (`b.count User, as: :users`).
`Pluckr::Batch.build { ... }` returns the batch unexecuted, with `#to_sql` and
`#fetch`.

The trade-off against a `Pluckr::Query`: a batch is bound to concrete records,
so it answers *one* subject per call. To fill a column across the rows of an
index page, define a query.

## DSL

| Node | Result | SQL |
| --- | --- | --- |
| `field :email` | `email` | selected column |
| `field :email, as: :contact` | `contact` | selected column |
| `one :subscription do ... end` | `subscription` (or `nil`) | `LEFT OUTER JOIN` |
| `one :plan, via: :subscription do ... end` | `plan` | `LEFT OUTER JOIN` |
| `first :comment, via: :comments do ... end` | `comment` (or `nil`) | correlated subquery per column, `LIMIT 1` |
| `last :comment, via: :comments, order: :created_at do ... end` | `comment` | correlated subquery per column, `LIMIT 1` |
| `exists :photos` | `photos_exists` | correlated `EXISTS`, index probe per row |
| `exists :photos, as: :has_photos` | `has_photos` | correlated `EXISTS` |
| `count :videos` | `videos_count` | scalar subquery |
| `count :videos, as: :n_videos` | `n_videos` | scalar subquery |
| `count :users, from: User` | `users` | scalar subquery |
| `sum/avg/min/max ..., column: :amount` | `<name>_sum`, `<name>_avg`, ... | scalar subquery |

`exists`, `count`, `sum`, `avg`, `min` and `max` all take `where:` and `scope:`
(`average` is an alias of `avg`, and both name their output `<name>_avg`):

```ruby
count :active_accounts, from: Account, where: { active: true }
count :active_accounts, from: Account, scope: ->(rel) { rel.active }

count  :big_videos, via: :videos, scope: ->(rel) { rel.where(size: 100..) }
exists :recent_photos, via: :photos, scope: -> { Photo.where(created_at: 1.week.ago..) }
```

`scope:` receives the target model's relation (or nothing, if the callable takes
no arguments) and must return a relation for the same model. It runs on every
compilation, so runtime values stay fresh.

`where:` takes a Hash **or** a zero-argument callable returning one (`scope:` is
the one that receives the relation). The difference matters:

```ruby
# evaluated once, when the class loads - this asks about the week before boot,
# forever
count :recent_orders, from: Order, where: { created_at: 1.week.ago.. }

# evaluated on every compilation - what you almost certainly meant
count :recent_orders, from: Order, where: -> { { created_at: 1.week.ago.. } }
```

A Hash is validated against the model's columns when the class loads; a callable
is validated each time it runs, so an unknown column raises `Pluckr::UnknownField`
on the first `to_sql`/`fetch` instead. Either way values go through ActiveRecord
quoting.

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

### One row out of many

`one` follows a singular association. To take a single row out of a collection -
the latest comment, the first order - use `first`/`last`:

```ruby
class UserSummary < Pluckr::Query
  source User

  schema do
    field :email

    last :comment, via: :comments do          # newest by primary key
      field :body
      field :created_at
    end

    last :signup_order, via: :orders, order: :created_at do
      field :amount
    end
  end
end

user.comment.body        # => "the latest one"   (nil if there are none)
user.signup_order.amount
```

Ordering follows ActiveRecord: `last` takes the final row of the given order, so
`last ..., order: { created_at: :asc }` is what `comments.order(created_at:
:asc).last` returns. Without `order:` it is the primary key. The primary key is
always appended as a tiebreaker, so every selected column comes from the same
row even when the ordering has duplicates.

Each selected column compiles to its own correlated subquery with `LIMIT 1` -
no join, so root rows are never multiplied, and no window functions, so it works
the same on all three adapters. The cost is one indexed subquery per column;
keep these blocks small, and index the foreign key with the ordering column
(`add_index :comments, [:user_id, :created_at]`).

In v0.1 a `first`/`last` block may only contain `field`s - anything needing a
join of its own is rejected with a descriptive error - and it takes no `where:`
or `scope:`, so "the latest *published* comment" is not expressible yet. A
scoped association (`has_many :published_comments, -> { ... }`) does not help:
Pluckr refuses those, because it would silently drop the scope.

On PostgreSQL each of these plans as an `Index Scan Backward … loops=<page size>`
- one probe per row per column, no hashing - so the `LIMIT 1 OFFSET 0` fence
`exists` needs is not needed here.

### `one` requires a genuinely singular association

`one` compiles to a `LEFT OUTER JOIN`, which is only safe while the association
really is singular. If a `has_one` has two matching rows - no unique index, an
import that ran twice - the join returns the parent row twice, so `fetch`
returns duplicate result objects and `limit(20)` covers fewer than 20 records.

ActiveRecord hides this (`user.subscription` just picks one row); SQL does not.
Put a unique index on the association's foreign key:

```ruby
add_index :subscriptions, :user_id, unique: true   # has_one :subscription
add_index :profiles, :owner_id, unique: true       # has_one :profile, foreign_key: :owner_id
```

`belongs_to` cannot duplicate - it points at a primary key. A future version may
compile `has_one` as a subquery so the index stops being a requirement.

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
not `1` on every adapter, and aggregates answer what ActiveRecord would:
`count` and `sum` are `0` when nothing matched, `min`/`max`/`avg` are `nil`,
because no row means no minimum. `avg` is a `BigDecimal`, even over an integer
column.

They serialise as their data, so `render json:` does the obvious thing:

```ruby
result.to_json   # => {"id":1,"email":"...","subscription":{"name":"Pro"},"videos_count":2}
result.as_json   # => {"id" => 1, ...}
result.to_hash   # => {id: 1, ...}, so **result works too
```

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
`scope:` returning the wrong model, a `where:` callable returning something that
is not a Hash or naming an unknown column, `limit`/`offset`/`group` inside a
scope, output aliases longer than the database's identifier limit, and a query
whose models do not share a database connection.

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
| `batch.rb` | `Pluckr.batch` - aggregates over caller-supplied relations |
| `result/builder.rb` | flat row -> nested frozen objects, with type casting |

The compiler never sees DSL state, so new node types are additive.

## Not in v0.1

- `many` (nested collections)
- raw SQL fields, manual joins
- `has_many :through`, polymorphic `belongs_to`, associations with their own
  scope, and associations whose model has a `default_scope` (these raise
  `Pluckr::UnsupportedAssociation` rather than silently ignoring the scope).
  Polymorphic `has_many ..., as:` targets and STI children *are* supported, and
  `Pluckr.batch` handles all of them, since ActiveRecord builds the SQL.
- `where:`/`scope:` on `first`/`last`
- composite primary keys are readable, and `first` orders by every key column,
  but `find` needs a single-column key and says so
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
| `reload!` | pick up edits to `lib/` and `dev/` without restarting |
| `reseed!(users: 500)` | wipe and re-seed |
| `reset!` | reload the schema, then re-seed |
| `Dev.log!(false)` | stop echoing SQL (`Dev.log!` turns it back on) |
| `Dev.counts` | row counts per table |

Every statement is logged to stdout by default, so you see exactly what Pluckr
sends:

```
>> UserSummary.where(active: true).limit(2).fetch
  UserSummary Pluckr (0.6ms)  SELECT "users"."id" AS "id", ... LIMIT 2
```

### What is in `dev/`

| File | Contents |
| --- | --- |
| `dev/schema.rb` | users, subscriptions, plans, photos, videos, comments, accounts, orders - with the indexes a real app would have |
| `dev/models.rb` | the ActiveRecord models, including a self-referential `manager` / `direct_reports` |
| `dev/seeds.rb` | deterministic seed data |
| `dev/queries.rb` | `UserSummary`, `UserCard`, `DashboardStats` - aliases, nesting, `via:`, `where:`, `scope:`, dashboards |
| `dev/console_helpers.rb` | the helpers above |
| `dev/boot.rb` | connection, `Dev.reset!`, `Dev.seed!`, `Dev.log!` |

Edit `dev/queries.rb` - or the gem itself - and pick the changes up without
leaving the session:

```ruby
>> reload!
reloaded 20 files
>> sql UserSummary.limit(1)
```

`reload!` re-loads `lib/pluckr/**` and the sandbox files. Use `reset!` instead
when `dev/schema.rb` changed, since that needs the tables rebuilt.

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
