# frozen_string_literal: true

RSpec.describe "generated SQL" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }

  before do
    define_query("UserSummary") do
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
      end
    end

    define_query("DashboardStats") do
      schema do
        count :users, from: User
        count :comments, from: Comment
        count :active_accounts, from: Account, where: { active: true }
      end
    end
  end

  describe "one statement per execution" do
    it "for find" do
      expect(SqlCounter.capture { UserSummary.find(user.id) }.size).to eq(1)
    end

    it "for a filtered fetch" do
      expect(SqlCounter.capture { UserSummary.where(active: true).limit(10).fetch }.size).to eq(1)
    end

    it "for many rows (no N+1 on nested/exists/count nodes)" do
      4.times { |i| User.create!(email: "u#{i}@example.com") }

      statements = SqlCounter.capture { UserSummary.fetch }

      expect(statements.size).to eq(1)
    end

    it "for dashboard queries" do
      expect(SqlCounter.capture { DashboardStats.fetch }.size).to eq(1)
    end
  end

  describe "to_sql" do
    it "is available on the query class" do
      expect(UserSummary.to_sql).to start_with("SELECT ")
    end

    it "reflects chained conditions" do
      sql = UserSummary.where(active: true).order(created_at: :desc).limit(10).offset(5).to_sql

      expect(sql).to include("#{col(:users, :active)} = #{qv(true)}")
      expect(sql).to include("ORDER BY #{col(:users, :created_at)} DESC")
      expect(sql).to include("LIMIT 10")
      expect(sql).to include("OFFSET 5")
    end

    it "is available on aggregate-only queries" do
      expect(DashboardStats.to_sql).to start_with("SELECT (SELECT COUNT(*)")
    end

    it "does not execute anything" do
      expect(SqlCounter.capture { UserSummary.to_sql }).to be_empty
    end
  end

  describe "quoting and injection safety" do
    it "quotes string values in independent where conditions" do
      define_query("OrderStats") do
        schema do
          count :paid_orders, from: Order, where: { status: "paid" }
        end
      end

      expect(OrderStats.to_sql).to include("#{col(:orders, :status)} = #{qv('paid')}")
    end

    it "escapes hostile string values instead of interpolating them" do
      hostile = "paid'); DROP TABLE orders; --"

      define_query("OrderStats") do
        schema do
          count :paid_orders, from: Order, where: { status: hostile }
        end
      end

      expect(OrderStats.to_sql).to include(qv(hostile))
      expect(OrderStats.to_sql).not_to match(/=\s*'paid'\)/)
      expect(OrderStats.fetch.paid_orders).to eq(0)
      expect(Order.count).to eq(0) # table still exists
    end

    it "quotes values in root conditions" do
      expect(UserSummary.where(email: "o'brien@example.com").to_sql)
        .to include(qv("o'brien@example.com"))
    end
  end

  describe "shape" do
    it "never selects the whole source table" do
      expect(UserSummary.to_sql).not_to include("#{qt(:users)}.*")
    end

    it "never groups the root query" do
      expect(UserSummary.to_sql).not_to include("GROUP BY")
    end

    it "only joins singular associations" do
      sql = UserSummary.to_sql

      expect(sql.scan("LEFT OUTER JOIN").size).to eq(1)
      expect(sql).to include("LEFT OUTER JOIN #{aliased_table(:subscriptions, :pluckr_subscription)}")
    end
  end
end
