# AGENTS.md

Pluckr is a declarative read-query layer for ActiveRecord: a `Pluckr::Query`
subclass declares the shape of the data, and Pluckr compiles it into exactly one
SQL statement returning frozen, ActiveRecord-free result objects.

Ruby 3.2+, ActiveRecord 7.1+ (6.1 also passes the suite), PostgreSQL / MySQL /
SQLite.

## Layout

```
lib/pluckr/
  query.rb                   class-level API: source, schema, find, for, fetch, first, to_sql
  relation.rb                immutable chaining + WhereChain, delegates root filtering to AR
  batch.rb                   Pluckr.batch - ad-hoc aggregates over caller-supplied relations
  schema/definition.rb       evaluates the DSL, validates, builds the AST
  schema/scope.rb            one level of the AST (the nodes selected for one model)
  schema/{field,one,exists,aggregate,node}.rb   AST nodes
  schema/conditions.rb       shared `where:` handling (Hash or callable)
  reflection/association.rb  the only place that touches AR reflection
  compiler/sql.rb            AST + Arel -> one SQL statement
  result/builder.rb          flat row -> nested frozen objects, with type casting
  result/object.rb           generated readers, to_h/to_hash, as_json, inspect, ==
  aliases.rb                 SQL alias encoding, shared by compiler and builder
  errors.rb                  Pluckr::Error and its descendants
```

Pipeline: `DSL -> schema AST -> reflection -> SQL compiler -> flat row -> result object`.

## DSL surface

`source`, `schema`, and inside a schema: `field` (`as:`), `one` (`via:`, nests),
`first`/`last` (`via:`, `order:`, fields only),
`exists` and `count`/`sum`/`avg`/`min`/`max` (`as:`, `via:`, `from:`, `column:`,
`where:`, `scope:`; `average` aliases `avg`). Query classes answer `where`/`where.not`/`order`/`limit`/
`offset`/`find`/`find_by`/`for`/`first`/`last`/`take`/`fetch`/`count`/`exists?`/
`one?`/`many?`/`find_each`/`in_batches`/`explain`/`to_sql`/`source_model`
(`first`/`last`/`take` also take a count; all three have a bang version).
`first`/`last`/`take`/`one?`/`many?` are defined rather than left to Enumerable,
which would have read the whole chain to answer them. On a chain that already
pages they follow AR exactly: `first(n)` clamps to the page (`find_nth_with_limit`),
`last` reads the page and takes its tail (`find_last`), `one?`/`many?` go through
`limited_count` (`limit_value ? count : limit(2).count`) - and `take(n)` replaces
the limit, because AR's does. `find` takes ids or an array of them, sends a block
to Enumerable, and treats `find(nil)` as `RecordNotFound`, all like AR; the
several-ids form goes through `for_ids`, so it needs `field` on the primary key
the way `.for` and batching do, while a single id does not.
`count`/`size`/`exists?`/`any?`/`none?`/`empty?` are delegated to the root AR
relation and compile no nodes - Enumerable would have answered them by building
every result object first. A block or a pattern argument goes back to Enumerable
(`return super if args.any? || block_given?`), mirroring
`ActiveRecord::Relation#any?`. `find_each`/`in_batches` seek by primary key
(`WHERE id > <last>`, never `OFFSET`), reorder by it, need `field` on it, and
refuse a chain that already has a `limit`/`offset`.
`.for` takes one AR record, a collection of them, or a relation of the source
model: one SQL statement, collections aligned to input order (requires `field`
on the primary key). An unloaded relation becomes a subquery, so its rows are
never instantiated: only its conditions survive (`UNUSED_RELATION_VALUES` drops
`select`/`order`/preloads/`lock`). A `limit`/`offset` cannot survive that (the
subquery loses the ORDER BY the page depends on, and MySQL rejects
`IN (SELECT ... LIMIT ...)`), so a paginated relation is plucked to primary keys
first and read by id: two statements, nothing instantiated. That pluck keeps the
joins the order may depend on (`PAGINATED_RELATION_VALUES` drops only
`select`/`lock`); a relation that joins to preload (`eager_loading?` or
`includes_values`) is loaded instead, because its `LIMIT` counts parent rows and
`pluck` would cut the page mid fan-out - see `page_keys`. Keys read
non-strictly - a relation is a set of conditions, so
rows the query filters out are absent rather than `RecordNotFound`, which stays
the answer only for records the caller handed over. Only `group`/`having` raises.
Not an association on the AR model - never `has_pluckr`.

Every read of a compiled read model goes through `Pluckr.select_all`
(`lib/pluckr.rb`), which wraps `connection.select_all` in a `fetch.pluckr`
notification carrying `:name`, `:sql` and `:rows`. Add execution paths there, not
around it. Statements Pluckr does not compile stay ActiveRecord's and publish
nothing: `count`/`exists?` and the `pluck` a paginated `.for` runs first.

`Pluckr.batch` is the second entry point: it takes relations the caller already
built and wraps each one in a derived table, so ActiveRecord's own scoping
applies and none of the reflection rules below are involved. It reuses the
Aggregate node (with `relation:` instead of `model:`), the compiler's
`aggregate_only_sql` and the result builder - no separate execution path.

## How the SQL is built

- plain fields -> selected columns, never `SELECT users.*`
- `one` -> `LEFT OUTER JOIN` on an aliased table (`pluckr_<path>`), plus a hidden
  presence marker (`__pluckr.<path>.present`) selecting the association's primary
  key, so "missing row" stays distinct from "row with NULL columns". This assumes
  the association really is singular: a `has_one` with duplicate rows duplicates
  the parent row. Documented as requiring a unique index; compiling `has_one` as
  a subquery is the structural fix, deferred
- `exists` -> `EXISTS (SELECT 1 ... LIMIT 1 OFFSET 0)`. The `OFFSET 0` is an
  optimisation fence; without it PostgreSQL rewrites the correlated EXISTS into a
  hashed subplan that scans the whole child table (50x slower on a paged query).
  Do not "clean it up".
- `first`/`last` -> one correlated `LIMIT 1` subquery per selected column, never
  a join or a window function (SQLite has no LATERAL). The order always ends with
  the primary key so every column comes from the same row, and `last` inverts the
  requested order, matching `relation.order(...).last`
- `count`/`sum`/`avg`/`min`/`max` -> scalar subquery, never JOIN + GROUP BY
- `where:` is a Hash (validated at definition time) or a zero-argument callable
  returning one (invoked and validated on every compilation, so runtime values
  stay runtime values) - see `schema/conditions.rb`. `scope:` is the callable
  that receives the relation; a `where:` callable with arguments is rejected
- `first`/`last` take no `where:`/`scope:` yet; adding them means routing the
  picked subquery through a relation, like the correlated aggregates do
- `where:`/`scope:` on a correlated node -> the scope is nested in a derived table
  and correlated from outside, so a scope may join (or be) the table it
  correlates to without capturing the correlation
- independent aggregates (`from:`) -> `(SELECT COUNT(*) FROM ... WHERE ...)` built
  from an AR relation, so quoting and default scopes come from ActiveRecord
- STI type conditions and polymorphic `as:` type columns are added automatically
- a relation-rooted aggregate (`Pluckr.batch`) -> `(SELECT COUNT(*) FROM (<the
  relation's own SQL>) pluckr_batch_1)`. The caller's projection is kept when
  `DISTINCT`/`GROUP BY` applies to it and dropped otherwise; `order` is kept only
  when a `limit`/`offset` depends on it; eager loading and locks are dropped

## Tests

```bash
bundle exec rspec              # SQLite (default)
DB=postgres bundle exec rspec  # needs a running PostgreSQL
DB=mysql bundle exec rspec     # CI covers this one
```

387 examples. CI (`.github/workflows/ci.yml`) runs ruby 3.2/3.4 against all three
adapters, with the pinned ActiveRecord versions (`gemfiles/activerecord-7.1.gemfile`,
`gemfiles/activerecord-8.0.gemfile`) on SQLite. Changes must pass on SQLite **and**
PostgreSQL locally before pushing.

The test schema (`spec/support/database.rb`) is indexed like a production schema
- unique indexes on `has_one` foreign keys, composites for the paged list query,
STI and the polymorphic association. Keep it that way; benchmark numbers and
`EXPLAIN` output depend on it.

Assertions about SQL must build expected fragments with the helpers in
`spec/support/sql_helpers.rb` (`q`, `qt`, `col`, `qv`, `aliased_table`), never
with hard-coded double quotes - the three adapters quote differently.

## Dev sandbox

```bash
bin/setup      # create + seed the dev database (DB=sqlite|postgres|mysql)
bin/console    # IRB with dev/ loaded
```

`dev/` is a throwaway application: `schema.rb`, `models.rb`, `seeds.rb`
(deterministic), `queries.rb` (example read models) and `console_helpers.rb`
(`sql`, `explain`, `statements`, `reload!`). The console logs every statement by
default (`Dev.log!(false)` to stop) and `reload!` re-loads `lib/` plus `dev/`, so
gem edits can be tried without restarting. It is not part of the gem - `pluckr.gemspec`
only ships `lib/`. Query classes validate columns as they load, so `dev/boot.rb`
requires `queries.rb` only once the schema exists.

## Benchmarks

```bash
bundle exec ruby benchmarks/read_models.rb            # PostgreSQL, 50k users
DB=sqlite bundle exec ruby benchmarks/read_models.rb
```

`benchmarks/read_models.rb` seeds a dataset, runs the same read model as naive
ActiveRecord, hand-tuned ActiveRecord and Pluckr at four page sizes, verifies all
three return identical data, and prints `EXPLAIN ANALYZE`. Results and the
reasoning behind the generated SQL live in `BENCHMARKS.md`. Re-run both adapters
and update that file whenever the compiler's output changes.

## Rules

- Keep the layers separated. The compiler reads the AST only, never DSL state.
- Validate in `schema/definition.rb`, at class-definition time, with a descriptive
  error class from `errors.rb`. Only checks that genuinely need compile-time
  context (a `scope:`'s return value, alias length) may raise later.
- Never interpolate values into SQL. Conditions go through ActiveRecord or Arel;
  identifiers are validated against `column_names` / reflection first.
- Never instantiate ActiveRecord objects for the rows a query returns. The one
  place records are loaded is `page_keys`, and only for a relation the caller
  already told ActiveRecord to preload.
- One SQL statement per execution. `has_many` is never joined, and everything a
  query touches must live on one connection pool - checked when compiling,
  walking nested scopes, and when a batch entry is added.
- Composite primary keys work for reading and for `first`; `find` refuses them
  with a message rather than building `table.["a", "b"]`.
- The compiler holds no mutable state between calls - it compiles fresh on every
  `apply`, so `scope:` callables are re-evaluated and the object stays thread-safe.
- Compose Arel nodes into the outer relation; do not call `to_sql` on a bare Arel
  manager. An STI `type_condition` carries a bind parameter that only the outer
  relation can render - stringifying early emits `= ?` and silently matches
  nothing.
- Adapter-neutral: build SQL with Arel, quote through the connection, and cast
  result values with the model's column types (only PostgreSQL returns typed
  values for raw SQL). Where SQL and ActiveRecord disagree, follow ActiveRecord:
  `sum` over no rows is 0, not NULL (`Result::Builder::Caster#default`), and an
  `avg` is a BigDecimal rather than the column's own type.
- Every behavior change needs specs, including the SQL shape and, where it
  matters, a statement count via `SqlCounter.capture`.
- Prefer failing loudly over compiling questionable SQL.

## Not in v0.1

`many` (nested collections), raw SQL fields, manual joins, writes. Associations
that are `:through`, polymorphic `belongs_to`, scoped, or whose model has a
`default_scope` raise `Pluckr::UnsupportedAssociation` rather than compiling to
wrong SQL - keep it that way until they are properly supported. Polymorphic
`has_many ..., as:` and STI children are supported.
