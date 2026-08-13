# Benchmarks

## TL;DR

Two read models, fetched three ways each. PostgreSQL 17, 50k users, indexed
schema.

**`UserSummary`** - `id`, `email`, a nested `subscription.plan`, an existence
check and a count:

| rows | ActiveRecord, N+1 | ActiveRecord, preloaded + grouped | Pluckr |
| ---: | ---: | ---: | ---: |
| 1 | 5 SQL / 0.46 ms | - | **1 SQL / 0.24 ms** |
| 10 | 49 SQL / 5.00 ms | 5 SQL / 0.85 ms | **1 SQL / 0.36 ms** |
| 100 | 481 SQL / 49.1 ms | 5 SQL / 2.89 ms | **1 SQL / 0.96 ms** |
| 1,000 | 4,801 SQL / 493 ms | 5 SQL / 23.6 ms | **1 SQL / 12.3 ms** |
| 10,000 | 48,001 SQL / 4,882 ms | 5 SQL / 290 ms | **1 SQL / 98.3 ms** |

**`UserCard`** - the wide version: 3 fields with aliases, a nested
`subscription.plan`, a self-referential `manager`, an existence check, three
counts (one of them scoped) and a sum:

| rows | ActiveRecord, N+1 | ActiveRecord, preloaded + grouped | Pluckr |
| ---: | ---: | ---: | ---: |
| 10 | 89 SQL / 9.95 ms | 10 SQL / 1.75 ms | **1 SQL / 1.05 ms** |
| 100 | 881 SQL / 98.9 ms | 10 SQL / 6.00 ms | **1 SQL / 2.42 ms** |
| 1,000 | 8,801 SQL / 1,185 ms | 10 SQL / 69.3 ms | **1 SQL / 26.9 ms** |
| 10,000 | 88,001 SQL / 10,404 ms | 10 SQL / 660 ms | **1 SQL / 242 ms** |

- **2-3x faster than careful hand-written ActiveRecord**, which needs 5
  statements (10 for the wide card) and ~25-40 lines to avoid the N+1.
  **10-51x faster** than the N+1.
- **The wider the read model, the more it saves.** Every node the wide card adds
  costs ActiveRecord another statement; Pluckr still sends one.
- **1 statement, always.** Over a networked database that is worth another
  `(statements - 1) x round_trip` per request: ~6 ms saved per 100-row page at a
  1 ms round trip, ~500 ms against an N+1.
- **`.for` in bulk, never per record.** The same 100 records read one call at a
  time cost 100 statements and 139 ms; `.for(records)` costs 1 statement and
  4.2 ms - 33x, and 86x at 10,000 records.
- **Same story on SQLite** (2.5-2.8x on lists) where round trips are free, so the
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
compares bulk `.for` against one call per record, checks that the variants return
identical data, and prints `EXPLAIN ANALYZE` for the SQL Pluckr generates.

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
| Software | Ruby 3.4.5, ActiveRecord 8.1.3.1 |
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
| ActiveRecord, record + questions | 1 | 5 | 0.456 | 680 | 1.9x |
| Pluckr | 1 | 1 | 0.240 | 433 | 1.0x |
| **List** | | | | | |
| ActiveRecord, N+1 | 10 | 49 | 4.999 | 6,555 | 14.0x |
| ActiveRecord, preloaded + grouped | 10 | 5 | 0.846 | 1,325 | 2.4x |
| Pluckr | 10 | 1 | 0.356 | 907 | 1.0x |
| ActiveRecord, N+1 | 100 | 481 | 49.050 | 64,246 | 51.2x |
| ActiveRecord, preloaded + grouped | 100 | 5 | 2.893 | 4,982 | 3.0x |
| Pluckr | 100 | 1 | 0.958 | 5,750 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 4,801 | 493.255 | 641,146 | 40.1x |
| ActiveRecord, preloaded + grouped | 1,000 | 5 | 23.594 | 41,528 | 1.9x |
| Pluckr | 1,000 | 1 | 12.287 | 54,170 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 48,001 | 4882.034 | 6,410,146 | 49.7x |
| ActiveRecord, preloaded + grouped | 10,000 | 5 | 289.942 | 406,928 | 2.9x |
| Pluckr | 10,000 | 1 | 98.314 | 538,370 | 1.0x |
| **Records already in memory (`.for`)** | | | | | |
| Pluckr, .for per record | 10 | 10 | 7.521 | 4,135 | 6.5x |
| Pluckr, .for in bulk | 10 | 1 | 1.149 | 918 | 1.0x |
| Pluckr, .for per record | 100 | 100 | 139.117 | 41,197 | 32.9x |
| Pluckr, .for in bulk | 100 | 1 | 4.224 | 5,941 | 1.0x |
| Pluckr, .for per record | 1,000 | 1,000 | 1018.621 | 411,817 | 40.2x |
| Pluckr, .for in bulk | 1,000 | 1 | 25.310 | 56,161 | 1.0x |
| Pluckr, .for per record | 10,000 | 10,000 | 9926.334 | 4,118,017 | 86.1x |
| Pluckr, .for in bulk | 10,000 | 1 | 115.311 | 558,361 | 1.0x |
| **Wide card (`UserCard`)** | | | | | |
| ActiveRecord, N+1 | 10 | 89 | 9.947 | 13,655 | 9.5x |
| ActiveRecord, preloaded + grouped | 10 | 10 | 1.752 | 2,918 | 1.7x |
| Pluckr | 10 | 1 | 1.047 | 1,806 | 1.0x |
| ActiveRecord, N+1 | 100 | 881 | 98.851 | 135,246 | 40.8x |
| ActiveRecord, preloaded + grouped | 100 | 10 | 6.000 | 12,609 | 2.5x |
| Pluckr | 100 | 1 | 2.422 | 10,249 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 8,801 | 1185.026 | 1,351,146 | 44.1x |
| ActiveRecord, preloaded + grouped | 1,000 | 10 | 69.320 | 109,465 | 2.6x |
| Pluckr | 1,000 | 1 | 26.873 | 94,669 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 88,001 | 10404.482 | 13,510,146 | 43.0x |
| ActiveRecord, preloaded + grouped | 10,000 | 10 | 660.462 | 1,077,865 | 2.7x |
| Pluckr | 10,000 | 1 | 242.032 | 938,869 | 1.0x |
| **Dashboard, 3 counts** | | | | | |
| ActiveRecord, three counts | 1 | 3 | 2.887 | 262 | 1.1x |
| Pluckr | 1 | 1 | 2.575 | 293 | 1.0x |

## SQLite

```
adapter: SQLite  users: 50000  pages: 10, 100, 1000, 10000  runs: 25
```

| | rows | SQL | median ms | allocations | vs Pluckr |
| --- | ---: | ---: | ---: | ---: | ---: |
| **Single record** | | | | | |
| ActiveRecord, record + questions | 1 | 5 | 0.393 | 667 | 2.3x |
| Pluckr | 1 | 1 | 0.173 | 438 | 1.0x |
| **List** | | | | | |
| ActiveRecord, N+1 | 10 | 49 | 3.608 | 6,422 | 15.8x |
| ActiveRecord, preloaded + grouped | 10 | 5 | 0.606 | 1,305 | 2.7x |
| Pluckr | 10 | 1 | 0.228 | 903 | 1.0x |
| ActiveRecord, N+1 | 100 | 481 | 36.130 | 63,033 | 45.2x |
| ActiveRecord, preloaded + grouped | 100 | 5 | 2.190 | 4,329 | 2.7x |
| Pluckr | 100 | 1 | 0.799 | 5,655 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 4,801 | 385.864 | 629,138 | 54.0x |
| ActiveRecord, preloaded + grouped | 1,000 | 5 | 18.120 | 37,608 | 2.5x |
| Pluckr | 1,000 | 1 | 7.148 | 53,175 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 48,001 | 3811.984 | 6,290,153 | 51.6x |
| ActiveRecord, preloaded + grouped | 10,000 | 5 | 193.685 | 367,008 | 2.6x |
| Pluckr | 10,000 | 1 | 73.872 | 528,375 | 1.0x |
| **Records already in memory (`.for`)** | | | | | |
| Pluckr, .for per record | 10 | 10 | 1.748 | 4,185 | 7.5x |
| Pluckr, .for in bulk | 10 | 1 | 0.232 | 914 | 1.0x |
| Pluckr, .for per record | 100 | 100 | 18.336 | 41,697 | 18.4x |
| Pluckr, .for in bulk | 100 | 1 | 0.994 | 5,846 | 1.0x |
| Pluckr, .for per record | 1,000 | 1,000 | 182.634 | 416,817 | 21.8x |
| Pluckr, .for in bulk | 1,000 | 1 | 8.380 | 55,166 | 1.0x |
| Pluckr, .for per record | 10,000 | 10,000 | 1859.680 | 4,168,045 | 21.4x |
| Pluckr, .for in bulk | 10,000 | 1 | 86.858 | 548,366 | 1.0x |
| **Wide card (`UserCard`)** | | | | | |
| ActiveRecord, N+1 | 10 | 89 | 7.316 | 13,662 | 13.7x |
| ActiveRecord, preloaded + grouped | 10 | 10 | 1.222 | 2,882 | 2.3x |
| Pluckr | 10 | 1 | 0.533 | 1,799 | 1.0x |
| ActiveRecord, N+1 | 100 | 881 | 75.601 | 135,432 | 46.5x |
| ActiveRecord, preloaded + grouped | 100 | 10 | 4.626 | 11,036 | 2.8x |
| Pluckr | 100 | 1 | 1.626 | 10,162 | 1.0x |
| ActiveRecord, N+1 | 1,000 | 8,801 | 816.248 | 1,353,191 | 53.5x |
| ActiveRecord, preloaded + grouped | 1,000 | 10 | 40.757 | 100,701 | 2.7x |
| Pluckr | 1,000 | 1 | 15.258 | 93,671 | 1.0x |
| ActiveRecord, N+1 | 10,000 | 88,001 | 8198.801 | 13,530,145 | 56.6x |
| ActiveRecord, preloaded + grouped | 10,000 | 10 | 404.122 | 988,101 | 2.8x |
| Pluckr | 10,000 | 1 | 144.755 | 928,882 | 1.0x |
| **Dashboard, 3 counts** | | | | | |
| ActiveRecord, three counts | 1 | 3 | 0.153 | 271 | 1.0x |
| Pluckr | 1 | 1 | 0.158 | 291 | 1.0x |

SQLite is in the same process, so its round trips are nearly free - and Pluckr
still wins by 2.5-2.8x on lists, because the work it avoids is instantiating
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
