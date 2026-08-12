# AGENTS.md

Pluckr is a declarative read-query layer for ActiveRecord: a `Pluckr::Query`
subclass declares the shape of the data, and Pluckr compiles it into one SQL
statement returning frozen, ActiveRecord-free result objects.

## Layout

```
lib/pluckr/
  query.rb                  class-level API: source, schema, find, fetch, to_sql
  relation.rb               immutable chaining, delegates root filtering to AR
  schema/definition.rb      evaluates the DSL, validates, builds the AST
  schema/*.rb               AST nodes: field, one, exists, aggregate, scope
  reflection/association.rb the only place that touches AR reflection
  compiler/sql.rb           AST + Arel -> one SQL statement
  result/{builder,object}.rb flat row -> nested frozen objects
  aliases.rb                SQL alias encoding, shared by compiler and builder
```

Pipeline: `DSL -> schema AST -> reflection -> SQL compiler -> flat row -> result object`.

## Tests

```bash
bundle exec rspec              # SQLite (default)
DB=postgres bundle exec rspec  # needs a running PostgreSQL
DB=mysql bundle exec rspec     # CI covers this one
```

CI (`.github/workflows/ci.yml`) runs ruby 3.2/3.4 against all three adapters.
Changes must pass on SQLite and PostgreSQL locally before pushing.

## Rules

- Keep the layers separated. The compiler reads the AST only, never DSL state.
- Validate in `schema/definition.rb`, at class-definition time, with a
  descriptive error class from `errors.rb`. Fail early, not at query time.
- Never interpolate values into SQL. Conditions go through ActiveRecord or
  Arel; identifiers are validated against `column_names` / reflection first.
- Never instantiate ActiveRecord objects for selected rows.
- One SQL statement per execution. `has_many` is never joined - use correlated
  `EXISTS` / scalar subqueries so root rows are not multiplied.
- Adapter-neutral: build SQL with Arel and quote through the connection. Cast
  result values with the model's column types, since only PostgreSQL returns
  typed values for raw SQL.
- The compiler holds no mutable state between calls; `scope:` callables are
  re-evaluated on every compilation.
- Every behavior change needs specs, including the SQL shape and, where it
  matters, a statement count via `SqlCounter.capture`.

## Not in v0.1

`many` (nested collections), raw SQL fields, manual joins, writes. Associations
that are `:through`, polymorphic `belongs_to`, scoped, or whose model has a
`default_scope` raise `Pluckr::UnsupportedAssociation` rather than compiling to
wrong SQL - keep it that way until they are properly supported.
