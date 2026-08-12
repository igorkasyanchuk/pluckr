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
- `where:` accepts a callable returning a Hash, evaluated on every compilation,
  so `-> { { created_at: 1.week.ago.. } }` is not frozen at class-load time.
- Benchmarks in `benchmarks/read_models.rb`, results in `BENCHMARKS.md`.
