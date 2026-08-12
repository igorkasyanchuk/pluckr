# frozen_string_literal: true

RSpec.describe "aggregate-only (dashboard) queries" do
  before do
    define_query("DashboardStats") do
      schema do
        count :users, from: User
        count :comments, from: Comment

        count :active_accounts,
              from: Account,
              where: { active: true }
      end
    end
  end

  let!(:user) { User.create!(email: "user@example.com") }

  before do
    2.times { Comment.create!(user: user) }
    Account.create!(active: true)
    Account.create!(active: false)
  end

  it "has no source model" do
    expect(DashboardStats.source_model).to be_nil
  end

  it "returns one result object, not an array" do
    stats = DashboardStats.fetch

    expect(stats).to be_a(Pluckr::Result::Object)
    expect(stats).not_to be_a(Array)
  end

  it "reads each independent count" do
    stats = DashboardStats.fetch

    expect(stats.users).to eq(1)
    expect(stats.comments).to eq(2)
    expect(stats.active_accounts).to eq(1)
  end

  it "returns a flat to_h" do
    expect(DashboardStats.fetch.to_h).to eq(users: 1, comments: 2, active_accounts: 1)
  end

  it "compiles to scalar subqueries in a single statement" do
    sql = DashboardStats.to_sql

    expect(sql).to include("(SELECT COUNT(*) FROM #{qt(:users)}) AS #{q(:users)}")
    expect(sql).to include("(SELECT COUNT(*) FROM #{qt(:comments)}) AS #{q(:comments)}")
    expect(sql).to include(
      "(SELECT COUNT(*) FROM #{qt(:accounts)} " \
      "WHERE #{col(:accounts, :active)} = #{qv(true)}) AS #{q(:active_accounts)}"
    )
    expect(sql).to start_with("SELECT ")
    expect(sql).not_to include(";")
  end

  describe "other aggregate operations" do
    before do
      Order.create!(status: "paid", amount: 100)
      Order.create!(status: "paid", amount: 20)
      Order.create!(status: "pending", amount: 7)

      define_query("RevenueStats") do
        schema do
          sum :revenue, from: Order, column: :amount
          sum :paid_revenue, from: Order, column: :amount, where: { status: "paid" }
          min :smallest_order, from: Order, column: :amount
          max :largest_order, from: Order, column: :amount
        end
      end
    end

    it "supports sum, min and max" do
      stats = RevenueStats.fetch

      expect(stats.revenue).to eq(127)
      expect(stats.paid_revenue).to eq(120)
      expect(stats.smallest_order).to eq(7)
      expect(stats.largest_order).to eq(100)
    end
  end

  describe "mixed with a source query" do
    it "allows independent aggregates next to root fields" do
      define_query("UserWithGlobals") do
        source User

        schema do
          field :id
          count :total_users, from: User
        end
      end

      result = UserWithGlobals.find(user.id)

      expect(result.id).to eq(user.id)
      expect(result.total_users).to eq(1)
    end
  end
end
