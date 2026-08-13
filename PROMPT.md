# Pluckr — prompt for AI assistants

Copy everything below the line into a system prompt or project instructions when generating or reviewing Rails code that uses Pluckr.

---

You are working in a Rails app that uses **Pluckr** (`gem "pluckr"`): a declarative read-query layer for ActiveRecord. A `Pluckr::Query` subclass declares the shape of the data; Pluckr compiles it into **exactly one SQL statement** and returns frozen, ActiveRecord-free result objects.

## When to use it

Use Pluckr for read models: index/show payloads, admin tables, dashboards, job payloads. Do not use it for writes, nested collections (`has_many` arrays), or as a serializer framework.

Do **not** load ActiveRecord models and then project them. Do **not** add `has_pluckr` / `user.user_card` on models — that is N+1.

## Define a query

```ruby
class UserCard < Pluckr::Query
  source User

  schema do
    field :id
    field :email

    one :subscription do
      field :id
      field :name
    end

    exists :photos
    count :videos
    last :comment, via: :comments, order: :created_at do
      field :body
    end
  end
end
```

Lists and filters live on the query, not on `User`:

```ruby
UserCard.where(active: true).order(created_at: :desc).limit(50).fetch
UserCard.find(id)
UserCard.first
```

## Records you already have (`.for`)

When Ruby already holds AR records (or a relation of them), use `.for`. It is **one statement** for a collection, and keeps array order.

```ruby
UserCard.for(user)            # one object (RecordNotFound if gone)
UserCard.for(users)           # array, same order as `users`
UserCard.for(User.active)     # relation filtered in SQL, not loaded into Ruby
```

Rules for `.for`:

- a collection requires `field :id` (or `field :id, as: ...`) on the schema, so rows can be aligned to the input order; empty collection gives `[]`, a missing row raises `ActiveRecord::RecordNotFound`
- the query's own `where` still applies, so `Query.where(active: true).for(inactive_record)` raises `RecordNotFound`
- an unloaded relation is passed as a subquery, so only its conditions count: order and row count are the query's, not the relation's, and `lock` is dropped. `limit`/`offset` or `group`/`having` on it raises `Pluckr::ConfigurationError` - load the relation instead (`for(relation.to_a)`)
- do not pass a Pluckr query to `.for`; it takes AR records. Use `fetch`
- wrong model, or a composite primary key: `Pluckr::ConfigurationError`. Composite keys use `where(...).first`

Never do this:

```ruby
users.each { |u| UserCard.for(u) }   # N queries
users.map { |u| UserCard.find(u.id) }
```

## Dashboards and ad-hoc aggregates

No `source` → one object of independent subqueries:

```ruby
class DashboardStats < Pluckr::Query
  schema do
    count :users, from: User
    sum :paid, from: Order, column: :amount, where: { status: "paid" }
  end
end
DashboardStats.fetch
```

Runtime / association-scoped aggregates (including `:through`, scoped associations): `Pluckr.batch`.

```ruby
Pluckr.batch do |b|
  b.count user.videos, as: :video_count
  b.exists user.photos, as: :has_photos
end
```

## DSL rules

- `field` / `one` / `exists` / `count`/`sum`/`avg`/`min`/`max` / `first`/`last`
- `one` is singular only (`belongs_to` / `has_one`). `has_one` needs a unique index on the FK or `fetch` duplicates parent rows
- `has_many` is never joined; use `exists`, `count`, or `first`/`last` (fields only; no `where:`/`scope:` on pick nodes yet)
- `where:` on aggregates is a Hash or a **zero-argument** lambda `-> { { created_at: 1.week.ago.. } }`. Use `scope: ->(rel) { ... }` to receive the relation
- `:through`, polymorphic `belongs_to`, association scopes, and `default_scope` on the target raise `Pluckr::UnsupportedAssociation` — use `Pluckr.batch` instead
- Do not write SQL against joined table names (`subscriptions.name`); Pluckr aliases them (`pluckr_subscription`)
- Results: frozen objects, `to_h` / `as_json` / `to_json`. Not ActiveRecord. Missing `one` is `nil`

## SQL budget

Every `fetch` / `find` / `first` / `for` is one statement. If you emit more than one Pluckr query per request for the same screen, you are using it wrong — widen the schema or use `Pluckr.batch`.
