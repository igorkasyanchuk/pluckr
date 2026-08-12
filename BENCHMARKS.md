# Benchmarks

Everything here comes from [`benchmarks/read_models.rb`](benchmarks/read_models.rb),
which seeds a database, runs the same read model three ways, checks that all
three return identical data, and prints `EXPLAIN ANALYZE` for the SQL Pluckr
generates.

```bash
bundle exec ruby benchmarks/read_models.rb              # PostgreSQL, 5k users
USERS=50000 bundle exec ruby benchmarks/read_models.rb  # bigger dataset
PAGE=200 RUNS=50 bundle exec ruby benchmarks/read_models.rb
KEEP=1 EXPLAIN=0 bundle exec ruby benchmarks/read_models.rb   # leave the data, skip plans
```

## Setup

| | |
| --- | --- |
| Hardware | Apple M3 laptop, local PostgreSQL over a unix socket |
| Software | PostgreSQL 17, Ruby 3.4.5, ActiveRecord 8.1.3 |
| Dataset | 50k users (half active), 35k subscriptions, 5 plans, 60k photos, 75k videos, 50k comments, 2k accounts |
| Indexes | the defaults Rails' `t.references` creates: one on each foreign key |
| Read model | `id`, `email`, `subscription.name`, `subscription.plan.name`, `photos` exists, `videos` count |

`median ms` is the median of 15–25 timed runs, measured in Ruby around the whole
call, so it includes connection time, SQL execution and object construction.
`allocations` is `GC.stat(:total_allocated_objects)` for one call. Absolute
numbers on a laptop move ±50% between runs; the ratios are the point.

## Results

### 5,000 users

| | SQL | median ms | allocations | vs Pluckr |
| --- | ---: | ---: | ---: | ---: |
| **Single record** | | | | |
| ActiveRecord, record + questions | 5 | 0.443 | 680 | 1.8x |
| Pluckr | 1 | 0.252 | 399 | 1.0x |
| **List of 50** | | | | |
| ActiveRecord, N+1 | 241 | 23.885 | 32,196 | 37.0x |
| ActiveRecord, preloaded + grouped | 5 | 1.768 | 2,952 | 2.7x |
| Pluckr | 1 | 0.645 | 3,050 | 1.0x |
| **Dashboard, 3 counts** | | | | |
| ActiveRecord, three counts | 3 | 0.448 | 262 | 1.1x |
| Pluckr | 1 | 0.402 | 278 | 1.0x |

### 50,000 users

| | SQL | median ms | allocations | vs Pluckr |
| --- | ---: | ---: | ---: | ---: |
| **Single record** | | | | |
| ActiveRecord, record + questions | 5 | 0.453 | 680 | 1.8x |
| Pluckr | 1 | 0.253 | 399 | 1.0x |
| **List of 50** | | | | |
| ActiveRecord, N+1 | 241 | 24.647 | 32,196 | 32.6x |
| ActiveRecord, preloaded + grouped | 5 | 1.723 | 2,952 | 2.3x |
| Pluckr | 1 | 0.757 | 3,050 | 1.0x |
| **Dashboard, 3 counts** | | | | |
| ActiveRecord, three counts | 3 | 2.207 | 262 | 1.0x |
| Pluckr | 1 | 2.190 | 278 | 1.0x |

The "preloaded + grouped" row is the honest comparison: `includes(subscription:
:plan)` plus a `distinct.pluck` for existence plus a `group(:user_id).count`,
then merged in Ruby. It is what a careful developer writes, and it is 5
statements and ~25 lines. Pluckr is one statement and one class.

Two things do **not** improve: allocations on the list (Pluckr builds its own
result objects, so it lands where preloaded ActiveRecord lands - the saving is
against the N+1 version, 10x), and the dashboard counts, which are dominated by
`COUNT(*)` scans that no query shape can avoid.

## What the plans look like

### Single record — 0.027 ms in the database

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
                ->  Index Only Scan using index_videos_on_user_id on videos pluckr_sub_2
                      Index Cond: (user_id = users.id)
Execution Time: 0.027 ms
```

### List of 50 — 0.110 ms in the database

```
Limit (actual time=0.019..0.100 rows=50 loops=1)
  ->  Nested Loop Left Join
        ->  Merge Left Join
              ->  Index Scan using users_pkey on users     Filter: active
              ->  Index Scan using index_subscriptions_on_user_id on subscriptions
        SubPlan 1
          ->  Limit (loops=50)                             -- 50 index probes, not a scan
                ->  Index Only Scan using index_photos_on_user_id on photos
        SubPlan 2
          ->  Aggregate (loops=50)
                ->  Index Only Scan using index_videos_on_user_id on videos
Execution Time: 0.110 ms
```

`loops=50` on both subplans is the whole design: each correlated node is one
index probe per returned row, never a join that multiplies rows and never a
`GROUP BY` over the whole table.

### Dashboard — 4.7 ms in the database

```
Result (actual time=4.712..4.712 rows=1 loops=1)
  InitPlan 1 -> Aggregate -> Seq Scan on users     (50,000 rows, 2.303 ms)
  InitPlan 2 -> Aggregate -> Seq Scan on comments  (50,000 rows, 2.339 ms)
  InitPlan 3 -> Aggregate -> Seq Scan on accounts  (   666 rows, 0.068 ms)
```

Three independent aggregates, one round trip, each an `InitPlan` evaluated once.
The cost is the `COUNT(*)` scans themselves - exactly what three separate
ActiveRecord `.count` calls would pay, minus two round trips.

## Why `exists` is not `EXISTS`

`exists :photos` compiles to `COALESCE((SELECT TRUE FROM photos WHERE ... LIMIT
1), FALSE)` rather than `EXISTS (SELECT 1 FROM photos WHERE ...)`. That is not a
style choice. PostgreSQL turns a correlated `EXISTS` in the SELECT list into a
*hashed* subplan: it scans the entire child table once and builds a hash, which
is sensible for an unbounded query and disastrous for a page of 50.

Same query, 50k users / 60k photos, page of 50, only the existence expression
changed:

| Expression | median ms | plan on `photos` |
| --- | ---: | --- |
| `EXISTS (SELECT 1 ...)` | 4.75 | Seq Scan, 60,000 rows |
| `EXISTS (SELECT 1 ... LIMIT 1)` | 3.72 | Seq Scan, 60,000 rows |
| `(SELECT COUNT(*) ...) > 0` | 0.09 | Index Only Scan |
| `COALESCE((SELECT TRUE ... LIMIT 1), FALSE)` | **0.09** | Index Only Scan, stops at first row |

The trade-off is real but one-sided. On an unbounded fetch of all 25k active
users the hashed `EXISTS` wins - 9.4 ms against 13.6 ms - because one scan beats
25k probes. Pluckr optimises for the paged case, which is what read models are
for. Switching the compiler took the 50k list query from 4.9 ms to 0.76 ms.

## How it scales

Page size, 50k users, everything indexed:

| rows fetched | median ms |
| ---: | ---: |
| 1 | 0.53 |
| 50 | 1.19 |
| 200 | 3.90 |
| 1000 | 13.68 |

Roughly 13 µs per row past a fixed ~0.5 ms floor, and flat in table size: the
same page of 50 costs the same at 5k users and at 50k users. Correlated nodes
cost per *returned* row, not per stored row.

That holds only while the foreign keys are indexed. Dropping the index on
`videos.user_id` and re-running the same page of 50:

| | median ms |
| --- | ---: |
| with `index_videos_on_user_id` | 1.99 |
| without it | 91.11 |

46x, because each of the 50 count probes becomes a sequential scan of 75k rows.
Rails indexes `t.references` by default; if a foreign key in a Pluckr query is
not indexed, fix that before anything else.

## What to expect in production

These numbers were measured over a unix socket, where a round trip costs
~0.05-0.2 ms. Production is not that. On a managed database the round trip is
usually 0.3-1 ms in the same availability zone and 2-5 ms across zones, and that
term is multiplied by the number of statements:

```
request time ≈ statements × round_trip + Σ execution + hydration
```

For the list endpoint above, at a 1 ms round trip:

| | statements | round trips | execution | ≈ total |
| --- | ---: | ---: | ---: | ---: |
| ActiveRecord, N+1 | 241 | 241 ms | ~5 ms | **~246 ms** |
| ActiveRecord, preloaded + grouped | 5 | 5 ms | ~1 ms | **~6 ms** |
| Pluckr | 1 | 1 ms | ~0.2 ms | **~1.2 ms** |

So the further the database is, the more Pluckr's single statement is worth. The
gap against *careful* ActiveRecord is roughly `(statements - 1) × round_trip` per
request - a few milliseconds each, which matters at p99 and under connection
pool pressure more than it does in a benchmark. The gap against a forgotten
preload is two orders of magnitude.

Reasonable expectations for a real application:

- **Index and detail endpoints**: 1 statement instead of 4-10. Expect single-digit
  milliseconds saved per request, more if the database is a network hop away or
  the model has many associations.
- **Wide tables**: Pluckr selects only declared columns, so a 60-column `users`
  table with a 5-field read model transfers and parses a fraction of the bytes.
  The benchmark model is narrow, so it understates this.
- **Object churn**: no ActiveRecord instances, no attribute hashes, no dirty
  tracking. Against an N+1 the allocation drop is ~10x, which shows up as GC
  time under load rather than in a single-request median.
- **Dashboards**: the saving is round trips, not scan time. `COUNT(*)` over a
  large table is slow in PostgreSQL no matter who writes the SQL; for tables in
  the tens of millions use rollup tables or approximate counts and read *those*
  with Pluckr.
- **Page sizes**: keep them in the tens or low hundreds. Correlated nodes are
  cheap per row but they do add up, and a page of 1000 with five aggregate nodes
  is a different query than a page of 50.
- **Where it will not help**: unbounded fetches of entire tables (the hashed
  `EXISTS` case above), write paths, anything needing model callbacks or
  validations, and queries whose cost is a missing index rather than a round
  trip.

Verify on your own data before believing any of this: `UserSummary.to_sql` gives
you the statement, and `EXPLAIN ANALYZE` on it gives you the truth.
