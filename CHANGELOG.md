# Changelog

## 0.1.0

- Initial MVP: `source`, `field` (+ `as:`), `one` (+ `via:`, nested), `exists`,
  `count`/`sum`/`min`/`max` (correlated and independent), `where`/`order`/`limit`/`offset`,
  `find`, `fetch`, `to_sql`, immutable result objects.
- Compiles on PostgreSQL, MySQL and SQLite; values cast with the model's column types.
- Reflection support: custom foreign/primary keys, custom table names,
  self-referential associations, STI type conditions.
- Raises `Pluckr::UnsupportedAssociation` for :through, polymorphic, scoped and
  `default_scope`d associations instead of generating wrong SQL.
