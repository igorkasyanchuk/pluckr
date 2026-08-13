# Changelog

## 0.1.0 (unreleased)

- Initial MVP: `source`, `field` (+ `as:`), `one` (+ `via:`, nested), `exists`,
  `count`/`sum`/`min`/`max` (correlated and independent), `where`/`order`/`limit`/`offset`,
  `find`, `fetch`, `to_sql`, immutable result objects.
- Compiles on PostgreSQL, MySQL and SQLite; values cast with the model's column types.
- Reflection support: custom foreign/primary keys, custom table names,
  self-referential associations, STI type conditions.
- `where:` and `scope:` on `exists`/`count`/`sum`/`min`/`max`, correlated or independent.
- `where.not` on root queries.
- Raises `Pluckr::UnsupportedAssociation` for :through, polymorphic `belongs_to`,
  scoped and `default_scope`d associations instead of generating wrong SQL;
  polymorphic `has_many ..., as:` and STI children are supported.
- `exists` compiles to `EXISTS (... LIMIT 1 OFFSET 0)`; the fence keeps PostgreSQL
  from hashing the subquery into a full scan of the child table.
- Scoped correlated aggregates read through a derived table, so a scope may join
  (or be) the table it correlates to.
- `Pluckr.batch { |b| b.count relation, as: :name }` - ad-hoc aggregates over
  relations the caller already built, in one statement. Respects everything
  ActiveRecord applied, including `:through`, polymorphic, scoped and
  `default_scope`d associations.
- Result objects serialise as their data: `as_json`, `to_json` and `to_hash`, so
  `render json: result` no longer emits `{"attributes": {...}}`.
- `Query.for(record)`, `.for(records)` and `.for(relation)` fetch a read model
  for records already in memory, in one statement. Collections keep input order;
  an unloaded relation becomes a subquery of its conditions alone, a paginated
  one is resolved to primary keys first (two statements, its own page and order),
  and `group`/`having` raises instead of generating invalid SQL.
- `last`/`last!`/`take`/`take!` and a count for `first`/`last`/`take`
  (`first(10)`), read with a `LIMIT` rather than by hydrating the chain and
  throwing most of it away.
- `count`/`size`/`exists?`/`any?`/`none?`/`empty?`/`one?`/`many?` ask the database (`COUNT(*)`,
  `SELECT 1`) instead of letting Enumerable build every result object first; a
  block still sends `any?`/`none?` back to Enumerable.
- `find_by`/`find_by!` (ActiveRecord's arity: a condition is required) and
  `explain`, which explains the statement Pluckr runs.
- `find` takes several ids (or an array) and returns them in the order asked,
  sends a block to Enumerable, and treats `find(nil)` as `RecordNotFound` -
  ActiveRecord's behaviour in each case.
- `find_each`/`in_batches` read a whole chain in pages, seeking by primary key
  rather than paging with `OFFSET`. Needs `field` on the primary key; refuses a
  chain that already has a `limit`/`offset`.
- Every statement publishes an `ActiveSupport::Notifications` `fetch.pluckr`
  event with `:name`, `:sql` and `:rows`, covering `fetch`, `find`, `first`,
  `for` and `Pluckr.batch`.
- Composite primary keys no longer break `first`; `find`/`for` raise a descriptive
  error for them.
- Query subclasses inherit `source` and `schema` from the query they subclass.
- `first` orders by primary key when the relation has no order, like ActiveRecord.
- Reading two connection pools in one statement raises instead of producing a
  confusing SQL error.
- `order:` directions are case-insensitive; `:ASC` used to reach Arel unchanged.
- `first`/`last` select one row of a collection (`last :comment, via: :comments,
  order: :created_at do ... end`), compiled as one correlated `LIMIT 1` subquery
  per column, with the primary key as a tiebreaker so every column comes from the
  same row.
- `avg` (alias `average`) alongside `count`/`sum`/`min`/`max`, correlated,
  independent and in `Pluckr.batch`. Returns a BigDecimal, or nil over no rows,
  matching `relation.average`.
- `sum` returns 0 rather than nil when nothing matched, matching
  `relation.sum(:column)`; `min`/`max` still return nil.
- `where:` accepts a callable returning a Hash, evaluated on every compilation,
  so `-> { { created_at: 1.week.ago.. } }` is not frozen at class-load time.
- Benchmarks in `benchmarks/read_models.rb`, results in `BENCHMARKS.md`.
