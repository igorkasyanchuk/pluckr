# Benchmarks

Everything here comes from [`benchmarks/read_models.rb`](benchmarks/read_models.rb),
which seeds a database, runs the same read model three ways at four page sizes,
checks that all three return identical data, and prints `EXPLAIN ANALYZE` for the
SQL Pluckr generates.

```bash
bundle exec ruby benchmarks/read_models.rb            # PostgreSQL, 50k users
DB=sqlite bundle exec ruby benchmarks/read_models.rb  # SQLite, in memory
PAGES=25,250 USERS=200000 RUNS=50 bundle exec ruby benchmarks/read_models.rb
KEEP=1 EXPLAIN=0 bundle exec ruby benchmarks/read_models.rb   # leave the data, skip plans
```

## Setup

| | |
| --- | --- |
| Hardware | Apple M3 laptop, local PostgreSQL 17 over a unix socket; SQLite in memory |
| Software | Ruby 3.4.5, ActiveRecord 8.1.3 |
| Dataset | 50k users (25k active), 35k subscriptions, 5 plans, 60k photos, 75k videos, 50k comments, 2k accounts |
| Read model | `id`, `email`, `subscription.name`, `subscription.plan.name`, `photos` exists, `videos` count |

The schema is indexed the way a production schema should be, which is what makes
the numbers meaningful:

```ruby
add_index :users, :email, unique: true
add_index :users, %i[active id]           # the paged list query
add_index :users, :created_at
add_index :users, :manager_id
add_index :users, :region_code
add_index :subscriptions, :user_id, unique: true   # has_one
add_index :subscriptions, :plan_id
add_index :profiles, :owner_id, unique: true       # has_one, custom key
add_index :photos, :user_id
add_index :videos, :user_id
add_index :videos, %i[user_id size]                # filtered counts
add_index :comments, :user_id
add_index :documents, %i[user_id type]             # STI
add_index :likes, %i[likeable_type likeable_id]    # polymorphic
add_index :accounts, :active
add_index :orders, %i[status amount]
```

`median ms` is the median of timed runs measured in Ruby around the whole call,
so it includes connection time, SQL execution and object construction.
`allocations` is `GC.stat(:total_allocated_objects)` for one call. The N+1
variant gets fewer samples on the big pages because it issues 4 statements per
row. Absolute numbers on a laptop move ±30% between runs; the ratios are the
point.

## PostgreSQL

```
adapter: PostgreSQL  users: 50000  pages: 10, 100, 1000, 10000  runs: 25
```

| | rows | SQL | median ms | allocations | vs Pluckr |
| --- | ---: | ---: | ---: | ---: | ---: |
| **Single record** | | | | | |
| ActiveRecord, record + questions | 1 | 5 | 0.471 | 680 | 2.1x |
| Pluckr | 1 | 1 | 0.227 | 393 | 1.0x |
| **List** | | | | | |
| ActiveRecord, N+1 | 10 | 49 | 4.963 | 6,555 | 14.5x |
| ActiveRecord, preloaded + grouped | 10 | 5 | 0.764 | 1,325 | 2.2x |
| Pluckr | 10 | 1 | 0.342 | 891 | 1.0x |
| ActiveRecord, N+1 | 100 | 481 | 48.346 | 64,246 | 49.7x |
| ActiveRecord, preloaded + grouped | 100 | 5 | 2.829 | 4,982 | 2.9x |
| Pluckr | 100 | 1 | 0.972 | 5,734 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 4,801 | 490.752 | 641,146 | 40.2x |
| ActiveRecord, preloaded + grouped | 1,000 | 5 | 23.180 | 41,528 | 1.9x |
| Pluckr | 1,000 | 1 | 12.216 | 54,154 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 48,001 | 5410.225 | 6,410,146 | 55.0x |
| ActiveRecord, preloaded + grouped | 10,000 | 5 | 286.761 | 406,928 | 2.9x |
| Pluckr | 10,000 | 1 | 98.357 | 538,354 | 1.0x |
| **Dashboard, 3 counts** | | | | | |
| ActiveRecord, three counts | 1 | 3 | 2.440 | 262 | 1.2x |
| Pluckr | 1 | 1 | 1.996 | 278 | 1.0x |

## SQLite

```
adapter: SQLite  users: 50000  pages: 10, 100, 1000, 10000  runs: 25
```

| | rows | SQL | median ms | allocations | vs Pluckr |
| --- | ---: | ---: | ---: | ---: | ---: |
| **Single record** | | | | | |
| ActiveRecord, record + questions | 1 | 5 | 0.407 | 667 | 2.4x |
| Pluckr | 1 | 1 | 0.170 | 398 | 1.0x |
| **List** | | | | | |
| ActiveRecord, N+1 | 10 | 49 | 3.887 | 6,423 | 16.5x |
| ActiveRecord, preloaded + grouped | 10 | 5 | 0.638 | 1,305 | 2.7x |
| Pluckr | 10 | 1 | 0.236 | 887 | 1.0x |
| ActiveRecord, N+1 | 100 | 481 | 36.371 | 63,033 | 45.4x |
| ActiveRecord, preloaded + grouped | 100 | 5 | 2.159 | 4,329 | 2.7x |
| Pluckr | 100 | 1 | 0.801 | 5,639 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 4,801 | 375.054 | 629,139 | 54.6x |
| ActiveRecord, preloaded + grouped | 1,000 | 5 | 17.804 | 37,608 | 2.6x |
| Pluckr | 1,000 | 1 | 6.870 | 53,159 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 48,001 | 3753.041 | 6,290,148 | 51.4x |
| ActiveRecord, preloaded + grouped | 10,000 | 5 | 199.302 | 367,008 | 2.7x |
| Pluckr | 10,000 | 1 | 73.011 | 528,359 | 1.0x |
| **Dashboard, 3 counts** | | | | | |
| ActiveRecord, three counts | 1 | 3 | 0.131 | 271 | 1.0x |
| Pluckr | 1 | 1 | 0.127 | 276 | 1.0x |

SQLite is in the same process, so its round trips are nearly free - and Pluckr
still wins by 2.6-2.7x on lists, because the work it avoids is instantiating
ActiveRecord objects and running four queries' worth of AR machinery, not just
network latency. On a networked database the gap widens (see below).

The "preloaded + grouped" row is the honest comparison: `includes(subscription:
:plan)` plus a `distinct.pluck` for existence plus a `group(:user_id).count`,
then merged in Ruby. It is what a careful developer writes, and it is 5
statements and ~25 lines. Pluckr is one statement and one class.

Two things do **not** improve: allocations on lists (Pluckr builds its own result
objects, so it lands near preloaded ActiveRecord - the 10x saving is against the
N+1 version), and the dashboard, which is dominated by `COUNT(*)` scans that no
query shape avoids.

## What the plans look like

### Single record — 0.026 ms in the database

```
Limit (actual time=0.024..0.024 rows=1 loops=1)
  ->  Nested Loop Left Join
        ->  Index Scan using users_pkey on users
        ->  Index Scan using index_subscriptions_on_user_id on subscriptions pluckr_subscription
        SubPlan 1                                     -- exists :photos
          ->  Limit
                ->  Index Only Scan using index_photos_on_user_id on photos pluckr_sub_1
                      Index Cond: (user_id = users.id)
        SubPlan 2                                     -- count :videos
          ->  Aggregate
                ->  Index Only Scan using index_videos_on_user_id_and_size on videos pluckr_sub_2
                      Index Cond: (user_id = users.id)
Execution Time: 0.026 ms
```

### List of 10 — 0.039 ms in the database

```
Limit (actual time=0.019..0.038 rows=10 loops=1)
  ->  Nested Loop Left Join
        ->  Merge Left Join
              ->  Index Scan using users_pkey on users     Filter: active
              ->  Index Scan using index_subscriptions_on_user_id on subscriptions
        SubPlan 1
          ->  Limit (loops=10)                             -- 10 index probes, not a scan
                ->  Index Only Scan using index_photos_on_user_id on photos
                      Heap Fetches: 0
        SubPlan 2
          ->  Aggregate (loops=10)
                ->  Index Only Scan using index_videos_on_user_id_and_size on videos
                      Heap Fetches: 0
Execution Time: 0.039 ms
```

`loops=10` on both subplans is the whole design: each correlated node is one
index probe per returned row, never a join that multiplies rows and never a
`GROUP BY` over the whole table. `Heap Fetches: 0` means the covering indexes
answer both without touching the tables.

### Dashboard — 4.4 ms in the database

```
Result (actual time=4.422..4.422 rows=1 loops=1)
  InitPlan 1 -> Aggregate -> Index Only Scan on users      (50,000 rows, 2.268 ms)
  InitPlan 2 -> Aggregate -> Seq Scan on comments          (50,000 rows, 2.118 ms)
  InitPlan 3 -> Aggregate -> Seq Scan on accounts          (   666 rows, 0.036 ms)
```

Three independent aggregates, one round trip, each an `InitPlan` evaluated once.
The cost is the `COUNT(*)` scans themselves - exactly what three separate
ActiveRecord `.count` calls pay, minus two round trips.

## Why `exists` carries `LIMIT 1 OFFSET 0`

`exists :photos` compiles to:

```sql
EXISTS (SELECT 1 FROM photos WHERE photos.user_id = users.id LIMIT 1 OFFSET 0)
```

The tail is not decoration. Left alone, PostgreSQL turns a correlated `EXISTS` in
the SELECT list into a *hashed* subplan: it scans the entire child table once and
builds a hash. That is a good choice for an unbounded query and a terrible one
for a page of 50. `OFFSET 0` is the standard optimisation fence - it blocks the
rewrite, and the plan becomes an index probe per row that stops at the first
match. It parses on PostgreSQL, MySQL and SQLite, and is a no-op on the latter
two.

Same query, 50k users / 60k photos, page of 50, only the existence expression
changed:

| Expression | median ms | plan on `photos` |
| --- | ---: | --- |
| `EXISTS (SELECT 1 ...)` | 4.98 | Seq Scan, 60,000 rows |
| `EXISTS (... LIMIT 1)` | 4.11 | Seq Scan, 60,000 rows |
| `EXISTS (... ORDER BY 1)` | 4.64 | Seq Scan, 60,000 rows |
| `CASE WHEN EXISTS (...) THEN TRUE ELSE FALSE END` | 3.42 | Seq Scan, 60,000 rows |
| `COALESCE((SELECT TRUE ... LIMIT 1), FALSE)` | 0.15 | Index Only Scan |
| `EXISTS (... OFFSET 0)` | 0.07 | Index Only Scan |
| **`EXISTS (... LIMIT 1 OFFSET 0)`** | **0.07** | **Index Only Scan, stops at first row** |

Only the fence matters; `LIMIT 1` alone does nothing. The scalar `COALESCE` form
performs the same and was the first fix, but a real `EXISTS` reads better in
`to_sql` output and keeps the intent obvious, so that is what ships.

The trade-off is one-sided but real: on an unbounded fetch of all 25k active
users the hashed plan is competitive (~10 ms against ~15 ms), because one scan
beats 25k probes. Pluckr optimises for the paged case, which is what read models
are for.

## How it scales

From the tables above, PostgreSQL, per returned row:

| rows | median ms | µs per row |
| ---: | ---: | ---: |
| 1 | 0.227 | - |
| 10 | 0.342 | ~34 |
| 100 | 0.972 | ~10 |
| 1,000 | 12.216 | ~12 |
| 10,000 | 98.357 | ~10 |

Linear in rows returned past a ~0.2 ms floor, and flat in table size: a page of
100 costs the same at 5k users as at 50k. Correlated nodes cost per *returned*
row, not per stored row. Most of the per-row cost above 100 rows is Ruby building
result objects, not the database - the server-side time for a page of 10 is
0.039 ms.

That holds only while the foreign keys are indexed. Dropping both indexes on
`videos.user_id` and re-running a page of 100:

| | median ms |
| --- | ---: |
| indexed | 1.44 |
| no index on `videos.user_id` | 177.68 |

123x, because each of the 100 count probes becomes a sequential scan of 75k rows.
Rails indexes `t.references` by default; if a foreign key used by `exists` or
`count` is not indexed, fix that before anything else.

## What to expect in production

These numbers were measured over a unix socket, where a round trip costs
~0.05-0.2 ms. Production is not that. On a managed database the round trip is
usually 0.3-1 ms in the same availability zone and 2-5 ms across zones, and that
term is multiplied by the number of statements:

```
request time ≈ statements × round_trip + Σ execution + hydration
```

For a page of 100, at a 1 ms round trip:

| | statements | round trips | rest | ≈ total |
| --- | ---: | ---: | ---: | ---: |
| ActiveRecord, N+1 | 481 | 481 ms | ~48 ms | **~529 ms** |
| ActiveRecord, preloaded + grouped | 5 | 5 ms | ~2.8 ms | **~8 ms** |
| Pluckr | 1 | 1 ms | ~1.0 ms | **~2 ms** |

So the further the database is, the more one statement is worth. Against
*careful* ActiveRecord the saving is roughly `(statements - 1) × round_trip` per
request on top of the 2-3x measured here - a few milliseconds each, which shows
up at p99 and under connection pool pressure more than in a benchmark. Against a
forgotten preload it is two orders of magnitude.

Reasonable expectations for a real application:

- **Index and detail endpoints**: 1 statement instead of 4-10, and 2-3x lower
  latency even with the database on the same machine.
- **Wide tables**: Pluckr selects only declared columns, so a 60-column `users`
  table with a 5-field read model transfers and parses a fraction of the bytes.
  The benchmark model is narrow, so it understates this.
- **Object churn**: no ActiveRecord instances, no attribute hashes, no dirty
  tracking. Against an N+1 the allocation drop is ~10x, which shows up as GC time
  under load rather than in a single-request median.
- **Dashboards**: the saving is round trips, not scan time. `COUNT(*)` over a
  large table is slow in PostgreSQL no matter who writes the SQL; for tables in
  the tens of millions use rollup tables or approximate counts and read *those*
  with Pluckr.
- **Page sizes**: tens to low hundreds is the sweet spot. 10,000 rows in one
  query works (98 ms) but at that size you are paying for object construction,
  and something like `select_all` on a flat projection may serve you better.
- **Where it will not help**: unbounded fetches of entire tables, write paths,
  anything needing callbacks or validations, and queries whose real problem is a
  missing index rather than a round trip.

Verify on your own data before believing any of this: `UserSummary.to_sql` gives
you the statement, and `EXPLAIN ANALYZE` on it gives you the truth.
