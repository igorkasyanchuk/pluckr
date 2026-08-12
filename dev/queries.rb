# frozen_string_literal: true

# Example read models to play with in the console.

class UserSummary < Pluckr::Query
  source User

  schema do
    field :id
    field :email

    one :subscription do
      field :id
      field :name

      one :plan do
        field :name
        field :price_cents
      end
    end

    exists :photos
    count :videos
  end
end

# Aliases, a renamed association, scoped aggregates.
class UserCard < Pluckr::Query
  source User

  schema do
    field :id
    field :name, as: :full_name
    field :created_at, as: :joined_at

    one :plan, via: :subscription do
      field :name
    end

    one :manager do
      field :email
    end

    exists :photos, as: :has_photos
    count :videos, as: :video_count
    count :videos, as: :big_video_count, scope: ->(rel) { rel.where(size: 100..) }
    count :orders, as: :paid_order_count, where: { status: "paid" }
    sum :orders, column: :amount, as: :lifetime_value, where: { status: "paid" }
  end
end

class DashboardStats < Pluckr::Query
  schema do
    count :users, from: User
    count :active_users, from: User, where: { active: true }
    count :comments, from: Comment
    count :active_accounts, from: Account, scope: ->(rel) { rel.active }

    sum :paid_revenue, from: Order, column: :amount, where: { status: "paid" }
    max :last_signup, from: User, column: :created_at
  end
end
