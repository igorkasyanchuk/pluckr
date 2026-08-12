# AGENTS.md

Pluckr is a declarative read-query layer for ActiveRecord: a `Pluckr::Query`
subclass declares the shape of the data, and Pluckr compiles it into exactly one
SQL statement returning frozen, ActiveRecord-free result objects.

Ruby 3.2+, ActiveRecord 7.1+ (6.1 also passes the suite), PostgreSQL / MySQL /
SQLite.

## Layout

```
lib/pluckr/
  query.rb                   class-level API: source, schema, find, fetch, first, to_sql
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
`exists` and `count`/`sum`/`min`/`max` (`as:`, `via:`, `from:`, `column:`,
`where:`, `scope:`). Query classes answer `where`/`where.not`/`order`/`limit`/
`offset`/`find`/`first`/`fetch`/`to_sql`/`source_model`.

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
- `count`/`sum`/`min`/`max` -> scalar subquery, never JOIN + GROUP BY
- `where:` is a Hash (validated at definition time) or a callable returning one
  (invoked and validated on every compilation, so runtime values stay runtime
  values) - see `schema/conditions.rb`
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

191 examples. CI (`.github/workflows/ci.yml`) runs ruby 3.2/3.4 against all three
adapters. Changes must pass on SQLite **and** PostgreSQL locally before pushing.

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
- Never instantiate ActiveRecord objects for selected rows.
- One SQL statement per execution. `has_many` is never joined.
- The compiler holds no mutable state between calls - it compiles fresh on every
  `apply`, so `scope:` callables are re-evaluated and the object stays thread-safe.
- Adapter-neutral: build SQL with Arel, quote through the connection, and cast
  result values with the model's column types (only PostgreSQL returns typed
  values for raw SQL). Where SQL and ActiveRecord disagree, follow ActiveRecord:
  `sum` over no rows is 0, not NULL (`Result::Builder::Caster#default`).
- Every behavior change needs specs, including the SQL shape and, where it
  matters, a statement count via `SqlCounter.capture`.
- Prefer failing loudly over compiling questionable SQL.

## Not in v0.1

`many` (nested collections), raw SQL fields, manual joins, writes. Associations
that are `:through`, polymorphic `belongs_to`, scoped, or whose model has a
`default_scope` raise `Pluckr::UnsupportedAssociation` rather than compiling to
wrong SQL - keep it that way until they are properly supported. Polymorphic
`has_many ..., as:` and STI children are supported.
