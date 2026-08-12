# Benchmarks

## TL;DR

Two read models, fetched three ways each. PostgreSQL 17, 50k users, indexed
schema.

**`UserSummary`** - `id`, `email`, a nested `subscription.plan`, an existence
check and a count:

| rows | ActiveRecord, N+1 | ActiveRecord, preloaded + grouped | Pluckr |
| ---: | ---: | ---: | ---: |
| 1 | 5 SQL / 0.46 ms | - | **1 SQL / 0.25 ms** |
| 10 | 49 SQL / 4.95 ms | 5 SQL / 0.82 ms | **1 SQL / 0.35 ms** |
| 100 | 481 SQL / 49.0 ms | 5 SQL / 2.90 ms | **1 SQL / 0.99 ms** |
| 1,000 | 4,801 SQL / 493 ms | 5 SQL / 23.3 ms | **1 SQL / 11.7 ms** |
| 10,000 | 48,001 SQL / 4,872 ms | 5 SQL / 286 ms | **1 SQL / 98.5 ms** |

**`UserCard`** - the wide version: 3 fields with aliases, a nested
`subscription.plan`, a self-referential `manager`, an existence check, three
counts (one of them scoped) and a sum:

| rows | ActiveRecord, N+1 | ActiveRecord, preloaded + grouped | Pluckr |
| ---: | ---: | ---: | ---: |
| 10 | 89 SQL / 10.2 ms | 10 SQL / 1.77 ms | **1 SQL / 0.83 ms** |
| 100 | 881 SQL / 99.2 ms | 10 SQL / 6.15 ms | **1 SQL / 2.61 ms** |
| 1,000 | 8,801 SQL / 1,037 ms | 10 SQL / 68.9 ms | **1 SQL / 27.6 ms** |
| 10,000 | 88,001 SQL / 10,323 ms | 10 SQL / 588 ms | **1 SQL / 235 ms** |

- **2-3x faster than careful hand-written ActiveRecord**, which needs 5
  statements (10 for the wide card) and ~25-40 lines to avoid the N+1.
  **12-55x faster** than the N+1.
- **The wider the read model, the more it saves.** Every node the wide card adds
  costs ActiveRecord another statement; Pluckr still sends one.
- **1 statement, always.** Over a networked database that is worth another
  `(statements - 1) x round_trip` per request: ~6 ms saved per 100-row page at a
  1 ms round trip, ~500 ms against an N+1.
- **Same story on SQLite** (2.6-2.7x on lists) where round trips are free, so the
  win is not only latency - it is also the ActiveRecord object machinery Pluckr
  skips.
- **Correlated nodes cost per returned row, not per stored row**: a page of 100
  costs the same at 5k users as at 50k. Server-side time for a page of 10 is
  0.039 ms.
- **Index your foreign keys.** Without an index on `videos.user_id` the same page
  of 100 goes from 1.44 ms to 177 ms.
- Where it does not help: unbounded fetches of whole tables, dashboards whose
  cost is `COUNT(*)` scans, and anything whose real problem is a missing index.

Everything below is reproducible with `bundle exec ruby benchmarks/read_models.rb`.

## Where the numbers come from

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
| Read models | `UserSummary` (6 outputs, 1 join, 2 correlated nodes) and `UserCard` (12 outputs, 3 joins, 6 correlated nodes incl. a scoped count and a sum) |

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
add_index :orders, %i[user_id status]              # per-user order aggregates
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
| ActiveRecord, record + questions | 1 | 5 | 0.464 | 680 | 1.8x |
| Pluckr | 1 | 1 | 0.253 | 433 | 1.0x |
| **List** | | | | | |
| ActiveRecord, N+1 | 10 | 49 | 4.951 | 6,555 | 14.3x |
| ActiveRecord, preloaded + grouped | 10 | 5 | 0.816 | 1,325 | 2.4x |
| Pluckr | 10 | 1 | 0.347 | 907 | 1.0x |
| ActiveRecord, N+1 | 100 | 481 | 49.022 | 64,246 | 49.6x |
| ActiveRecord, preloaded + grouped | 100 | 5 | 2.896 | 4,982 | 2.9x |
| Pluckr | 100 | 1 | 0.988 | 5,750 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 4,801 | 493.261 | 641,146 | 42.3x |
| ActiveRecord, preloaded + grouped | 1,000 | 5 | 23.313 | 41,528 | 2.0x |
| Pluckr | 1,000 | 1 | 11.672 | 54,170 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 48,001 | 4871.963 | 6,410,146 | 49.5x |
| ActiveRecord, preloaded + grouped | 10,000 | 5 | 286.453 | 406,928 | 2.9x |
| Pluckr | 10,000 | 1 | 98.479 | 538,370 | 1.0x |
| **Wide card (`UserCard`)** | | | | | |
| ActiveRecord, N+1 | 10 | 89 | 10.239 | 13,655 | 12.3x |
| ActiveRecord, preloaded + grouped | 10 | 10 | 1.773 | 2,918 | 2.1x |
| Pluckr | 10 | 1 | 0.831 | 1,806 | 1.0x |
| ActiveRecord, N+1 | 100 | 881 | 99.205 | 135,246 | 38.1x |
| ActiveRecord, preloaded + grouped | 100 | 10 | 6.147 | 12,609 | 2.4x |
| Pluckr | 100 | 1 | 2.605 | 10,249 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 8,801 | 1036.559 | 1,351,146 | 37.5x |
| ActiveRecord, preloaded + grouped | 1,000 | 10 | 68.931 | 109,465 | 2.5x |
| Pluckr | 1,000 | 1 | 27.636 | 94,669 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 88,001 | 10323.441 | 13,510,146 | 44.0x |
| ActiveRecord, preloaded + grouped | 10,000 | 10 | 588.057 | 1,077,865 | 2.5x |
| Pluckr | 10,000 | 1 | 234.668 | 938,869 | 1.0x |
| **Dashboard, 3 counts** | | | | | |
| ActiveRecord, three counts | 1 | 3 | 2.570 | 262 | 1.3x |
| Pluckr | 1 | 1 | 2.009 | 293 | 1.0x |

## SQLite

```
adapter: SQLite  users: 50000  pages: 10, 100, 1000, 10000  runs: 25
```

| | rows | SQL | median ms | allocations | vs Pluckr |
| --- | ---: | ---: | ---: | ---: | ---: |
| **Single record** | | | | | |
| ActiveRecord, record + questions | 1 | 5 | 0.368 | 667 | 2.1x |
| Pluckr | 1 | 1 | 0.174 | 438 | 1.0x |
| **List** | | | | | |
| ActiveRecord, N+1 | 10 | 49 | 3.649 | 6,422 | 16.1x |
| ActiveRecord, preloaded + grouped | 10 | 5 | 0.604 | 1,305 | 2.7x |
| Pluckr | 10 | 1 | 0.227 | 903 | 1.0x |
| ActiveRecord, N+1 | 100 | 481 | 35.829 | 63,033 | 44.0x |
| ActiveRecord, preloaded + grouped | 100 | 5 | 2.163 | 4,329 | 2.7x |
| Pluckr | 100 | 1 | 0.815 | 5,659 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 4,801 | 375.093 | 629,139 | 49.3x |
| ActiveRecord, preloaded + grouped | 1,000 | 5 | 18.276 | 37,608 | 2.4x |
| Pluckr | 1,000 | 1 | 7.612 | 53,175 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 48,001 | 3690.561 | 6,290,153 | 50.4x |
| ActiveRecord, preloaded + grouped | 10,000 | 5 | 193.196 | 367,008 | 2.6x |
| Pluckr | 10,000 | 1 | 73.211 | 528,375 | 1.0x |
| **Wide card (`UserCard`)** | | | | | |
| ActiveRecord, N+1 | 10 | 89 | 8.047 | 13,662 | 14.4x |
| ActiveRecord, preloaded + grouped | 10 | 10 | 1.344 | 2,882 | 2.4x |
| Pluckr | 10 | 1 | 0.560 | 1,799 | 1.0x |
| ActiveRecord, N+1 | 100 | 881 | 73.868 | 135,432 | 42.4x |
| ActiveRecord, preloaded + grouped | 100 | 10 | 4.675 | 11,036 | 2.7x |
| Pluckr | 100 | 1 | 1.742 | 10,151 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 8,801 | 813.129 | 1,353,138 | 54.8x |
| ActiveRecord, preloaded + grouped | 1,000 | 10 | 39.918 | 100,701 | 2.7x |
| Pluckr | 1,000 | 1 | 14.837 | 93,671 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 88,001 | 8029.970 | 13,530,144 | 45.9x |
| ActiveRecord, preloaded + grouped | 10,000 | 10 | 422.320 | 988,101 | 2.4x |
| Pluckr | 10,000 | 1 | 174.790 | 928,871 | 1.0x |
| **Dashboard, 3 counts** | | | | | |
| ActiveRecord, three counts | 1 | 3 | 0.136 | 271 | 1.0x |
| Pluckr | 1 | 1 | 0.128 | 276 | 1.0x |

SQLite is in the same process, so its round trips are nearly free - and Pluckr
still wins by 2.6-2.7x on lists, because the work it avoids is instantiating
ActiveRecord objects and running four queries' worth of AR machinery, not just
network latency. On a networked database the gap widens (see below).

The "preloaded + grouped" row is the honest comparison: `includes(subscription:
:plan)` plus a `distinct.pluck` for existence plus a `group(:user_id).count`,
then merged in Ruby. It is what a careful developer writes, and it is 5
statements and ~25 lines. Pluckr is one statement and one class.

The wide card shows where that approach stops scaling: every extra aggregate is
another grouped query and another merge loop, so the hand-written version grows
to 10 statements and ~40 lines while Pluckr stays at one statement and one class
- and gets *relatively* faster as the model widens.

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

### Wide card, list of 10 — 0.104 ms in the database

Twelve outputs, three joined tables and six correlated subqueries, still one
statement and still index probes all the way down:

```
Limit (actual time=0.024..0.079 rows=10 loops=1)
  ->  Nested Loop Left Join
        ->  Nested Loop Left Join
              ->  Merge Left Join
                    ->  Index Scan using index_users_on_active_and_id on users
                    ->  Index Scan using index_subscriptions_on_user_id on subscriptions
              ->  Materialize -> Seq Scan on plans      (5 rows, cached)
        ->  Index Scan using users_pkey on users pluckr_manager   (loops=10)
              Index Cond: (id = users.manager_id)                 -- self-referential `one`
        SubPlan 1  Limit -> Index Only Scan on photos             (loops=10)  exists :photos
        SubPlan 2  Aggregate -> Index Only Scan on videos         (loops=10)  count :videos
        SubPlan 3  Aggregate -> Index Only Scan on videos         (loops=10)  scoped count
                     Index Cond: ((user_id = users.id) AND (size >= 200))
        SubPlan 4  Aggregate -> Index Only Scan on comments       (loops=10)  count :comments
        SubPlan 5  Aggregate -> Index Only Scan on orders         (loops=10)  count, where:
        SubPlan 6  Aggregate -> Index Only Scan on orders         (loops=10)  sum, where:
Execution Time: 0.104 ms
```

SubPlan 3 is the interesting one: `count :videos, scope: ->(rel) { rel.where(size:
200..) }` compiles to a derived table, PostgreSQL flattens it, and the scope's
condition ends up *inside* the index condition on `[user_id, size]`. The scoped
count costs the same as the unscoped one.

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
| 1 | 0.253 | - |
| 10 | 0.347 | ~35 |
| 100 | 0.988 | ~10 |
| 1,000 | 11.672 | ~12 |
| 10,000 | 98.479 | ~10 |

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
