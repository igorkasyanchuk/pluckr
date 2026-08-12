# frozen_string_literal: true

RSpec.describe "scope: and where: on aggregates" do
  let!(:user) { User.create!(email: "user@example.com") }

  describe "independent aggregates" do
    before do
      Account.create!(active: true)
      Account.create!(active: true)
      Account.create!(active: false)
    end

    it "accepts a lambda that ignores the relation and returns its own" do
      define_query("DashboardStats") do
        schema do
          count :active_accounts, from: Account, scope: ->(_) { Account.active }
        end
      end

      expect(DashboardStats.fetch.active_accounts).to eq(2)
      expect(DashboardStats.to_sql).to include("#{col(:accounts, :active)} = #{qv(true)}")
    end

    it "accepts a lambda that narrows the given relation" do
      define_query("DashboardStats") do
        schema do
          count :active_accounts, from: Account, scope: ->(rel) { rel.active }
        end
      end

      expect(DashboardStats.fetch.active_accounts).to eq(2)
    end

    it "accepts a zero-arity callable" do
      define_query("DashboardStats") do
        schema do
          count :active_accounts, from: Account, scope: -> { Account.active }
        end
      end

      expect(DashboardStats.fetch.active_accounts).to eq(2)
    end

    it "combines scope: with where:" do
      Order.create!(status: "paid", amount: 100)
      Order.create!(status: "paid", amount: 5)
      Order.create!(status: "void", amount: 100)

      define_query("RevenueStats") do
        schema do
          sum :big_paid_revenue,
              from: Order,
              column: :amount,
              where: { status: "paid" },
              scope: ->(rel) { rel.where(amount: 50..) }
        end
      end

      expect(RevenueStats.fetch.big_paid_revenue).to eq(100)
    end

    it "still runs as a single statement" do
      define_query("DashboardStats") do
        schema do
          count :accounts, from: Account
          count :active_accounts, from: Account, scope: ->(rel) { rel.active }
        end
      end

      expect(SqlCounter.capture { DashboardStats.fetch }.size).to eq(1)
    end

    it "quotes values coming from the scope" do
      define_query("OrderStats") do
        schema do
          count :hostile, from: Order, scope: ->(rel) { rel.where(status: "x' OR 1=1 --") }
        end
      end

      expect(OrderStats.to_sql).to include(qv("x' OR 1=1 --"))
      expect(OrderStats.fetch.hostile).to eq(0)
    end
  end

  describe "correlated aggregates" do
    before do
      Video.create!(user: user, size: 500)
      Video.create!(user: user, size: 10)
      Photo.create!(user: user, url: "https://example.com/a.jpg")
    end

    it "narrows a correlated count" do
      define_query("UserSummary") do
        source User

        schema do
          count :videos
          count :videos, as: :big_videos, scope: ->(rel) { rel.where(size: 100..) }
        end
      end

      result = UserSummary.find(user.id)

      expect(result.videos_count).to eq(2)
      expect(result.big_videos).to eq(1)
    end

    it "narrows a correlated exists" do
      define_query("UserSummary") do
        source User

        schema do
          exists :videos, as: :has_huge_video, scope: ->(rel) { rel.where(size: 10_000..) }
          exists :videos, as: :has_big_video, scope: ->(rel) { rel.where(size: 100..) }
        end
      end

      result = UserSummary.find(user.id)

      expect(result.has_huge_video).to be(false)
      expect(result.has_big_video).to be(true)
    end

    it "accepts where: on correlated nodes" do
      define_query("UserSummary") do
        source User

        schema do
          count :videos, as: :tiny_videos, where: { size: 10 }
          exists :videos, as: :has_tiny_video, where: { size: 10 }
        end
      end

      result = UserSummary.find(user.id)

      expect(result.tiny_videos).to eq(1)
      expect(result.has_tiny_video).to be(true)
    end

    it "keeps the correlation and stays one statement" do
      other = User.create!(email: "other@example.com")

      define_query("UserSummary") do
        source User

        schema do
          field :id
          count :videos, as: :big_videos, scope: ->(rel) { rel.where(size: 100..) }
        end
      end

      counts = nil
      statements = SqlCounter.capture { counts = UserSummary.order(:id).fetch }

      expect(statements.size).to eq(1)
      expect(counts.map(&:big_videos)).to eq([1, 0])
      expect(counts.map(&:id)).to eq([user.id, other.id])
    end

    it "narrows an average" do
      define_query("UserSummary") do
        source User

        schema do
          avg :videos, column: :size
          avg :videos, column: :size, as: :big_average, scope: ->(rel) { rel.where(size: 100..) }
          average :videos, column: :size, as: :tiny_average, where: { size: 10 }
        end
      end

      result = UserSummary.find(user.id)

      expect(result.videos_avg).to eq(user.videos.average(:size))
      expect(result.big_average).to eq(500)
      expect(result.tiny_average).to eq(10)
    end

    it "averages with a dynamic where" do
      floor = 400

      define_query("UserSummary") do
        source User

        schema { avg :videos, column: :size, where: -> { { size: floor.. } } }
      end

      expect(UserSummary.find(user.id).videos_avg).to eq(500)

      floor = 1

      expect(UserSummary.find(user.id).videos_avg).to eq(user.videos.average(:size))
    end

    it "applies scope on top of the STI type condition" do
      Report.create!(user: user, title: "Q1")
      Report.create!(user: user, title: "Q2")
      Document.create!(user: user, title: "Q1")

      define_query("UserDocs") do
        source User

        schema do
          count :reports, as: :q1_reports, scope: ->(rel) { rel.where(title: "Q1") }
        end
      end

      expect(UserDocs.find(user.id).q1_reports).to eq(1)
    end
  end

  describe "scopes that name the correlated table" do
    it "keeps the correlation when the scope joins that table" do
      active = User.create!(email: "active@example.com", active: true)
      inactive = User.create!(email: "inactive@example.com", active: false)
      Photo.create!(user: active, url: "https://example.com/a.jpg")
      Photo.create!(user: inactive, url: "https://example.com/b.jpg")
      Photo.create!(user: inactive, url: "https://example.com/c.jpg")

      define_query("UserSummary") do
        source User

        schema do
          field :email
          count :photos, as: :active_photos, scope: ->(rel) { rel.joins(:user).where(users: { active: true }) }
        end
      end

      expect(UserSummary.find(active.id).active_photos).to eq(1)
      expect(UserSummary.find(inactive.id).active_photos).to eq(0)
    end

    it "scopes a self-referential association" do
      boss = User.create!(email: "boss@example.com")
      User.create!(email: "report-a@example.com", manager: boss, active: true)
      User.create!(email: "report-b@example.com", manager: boss, active: false)

      define_query("UserSummary") do
        source User

        schema do
          field :email
          count :direct_reports, as: :active_reports, scope: ->(rel) { rel.where(active: true) }
          exists :direct_reports, as: :leads_anyone, scope: ->(rel) { rel.where(active: true) }
        end
      end

      result = UserSummary.find(boss.id)

      expect(result.active_reports).to eq(1)
      expect(result.leads_anyone).to be(true)
      expect(UserSummary.find(user.id).active_reports).to eq(0)
      expect(UserSummary.find(user.id).leads_anyone).to be(false)
    end

    it "stays a single statement across many rows" do
      2.times { |i| User.create!(email: "u#{i}@example.com", manager: user) }

      define_query("UserSummary") do
        source User

        schema do
          field :id
          count :direct_reports, as: :reports, scope: ->(rel) { rel.where(active: true) }
        end
      end

      results = nil
      statements = SqlCounter.capture { results = UserSummary.order(:id).fetch }

      expect(statements.size).to eq(1)
      expect(results.map(&:reports)).to eq([2, 0, 0])
    end
  end

  describe "dynamic where:" do
    before do
      Video.create!(user: user, size: 50)
      Video.create!(user: user, size: 500)
    end

    it "re-evaluates a callable on every compilation" do
      threshold = 100

      define_query("UserSummary") do
        source User

        schema do
          field :id
          count :videos, as: :big_videos, where: -> { { size: threshold.. } }
        end
      end

      expect(UserSummary.find(user.id).big_videos).to eq(1)

      threshold = 10

      expect(UserSummary.find(user.id).big_videos).to eq(2)
    end

    it "works for independent aggregates too" do
      status = "paid"
      Order.create!(status: "paid", amount: 10)
      Order.create!(status: "void", amount: 10)

      define_query("OrderStats") do
        schema { count :orders, from: Order, where: -> { { status: status } } }
      end

      expect(OrderStats.fetch.orders).to eq(1)

      status = "void"

      expect(OrderStats.fetch.orders).to eq(1)
    end

    it "works for exists" do
      flag = 10_000

      define_query("UserSummary") do
        source User

        schema { exists :videos, as: :has_huge, where: -> { { size: flag.. } } }
      end

      expect(UserSummary.find(user.id).has_huge).to be(false)

      flag = 100

      expect(UserSummary.find(user.id).has_huge).to be(true)
    end

    it "keeps quoting values" do
      define_query("OrderStats") do
        schema { count :orders, from: Order, where: -> { { status: "x' OR 1=1 --" } } }
      end

      expect(OrderStats.to_sql).to include(qv("x' OR 1=1 --"))
      expect(OrderStats.fetch.orders).to eq(0)
    end

    it "validates the columns it returns, at compile time" do
      define_query("Bad") do
        source User

        schema { count :videos, where: -> { { nope: 1 } } }
      end

      expect { Bad.to_sql }.to raise_error(Pluckr::UnknownField, "Video does not have column `nope`")
    end

    it "rejects a callable that does not return a Hash" do
      define_query("Bad") do
        source User

        schema { count :videos, where: -> { "size > 1" } }
      end

      expect { Bad.to_sql }
        .to raise_error(Pluckr::ConfigurationError, /a `where:` lambda must return a Hash/)
    end

    it "still checks a Hash at definition time" do
      expect do
        define_query("Bad") do
          source User

          schema { count :videos, where: { nope: 1 } }
        end
      end.to raise_error(Pluckr::UnknownField, "Video does not have column `nope`")
    end
  end

  describe "errors" do
    it "rejects a non-callable scope at definition time" do
      expect do
        define_query("Bad") do
          schema do
            count :accounts, from: Account, scope: { active: true }
          end
        end
      end.to raise_error(Pluckr::ConfigurationError, /`count :accounts, scope:` expects a callable/)
    end

    it "rejects a scope returning the wrong model" do
      define_query("Bad") do
        schema do
          count :accounts, from: Account, scope: ->(_) { Order.all }
        end
      end

      expect { Bad.to_sql }
        .to raise_error(Pluckr::ConfigurationError, /must return an ActiveRecord::Relation for Account/)
    end

    it "rejects a scope returning something that is not a relation" do
      define_query("Bad") do
        schema do
          count :accounts, from: Account, scope: ->(_) { [1, 2, 3] }
        end
      end

      expect { Bad.to_sql }.to raise_error(Pluckr::ConfigurationError, /must return an ActiveRecord::Relation/)
    end

    it "allows scope: on the same model once the owner is an aliased join" do
      boss = User.create!(email: "boss@example.com")
      user.update!(manager: boss)
      User.create!(email: "quiet@example.com", manager: boss, active: false)

      define_query("UserSummary") do
        source User

        schema do
          one :manager do
            field :email
            count :direct_reports, as: :active_reports, scope: ->(rel) { rel.where(active: true) }
          end
        end
      end

      expect(UserSummary.find(user.id).manager.active_reports).to eq(1)
    end

    it "rejects scopes that reshape the subquery into more or fewer than one value" do
      define_query("Limited") do
        source User

        schema { count :photos, scope: ->(rel) { rel.limit(2) } }
      end

      define_query("Grouped") do
        schema { count :photos, from: Photo, scope: ->(rel) { rel.group(:url) } }
      end

      expect { Limited.to_sql }.to raise_error(Pluckr::ConfigurationError, /may not use limit/)
      expect { Grouped.to_sql }.to raise_error(Pluckr::ConfigurationError, /may not use group/)
    end

    it "ignores select/order noise from a scope" do
      Photo.create!(user: user, url: "https://example.com/a.jpg")

      define_query("UserSummary") do
        source User

        schema do
          count :photos, scope: ->(rel) { rel.select(:id).order(:url) }
        end
      end

      expect(UserSummary.find(user.id).photos_count).to eq(1)
    end

    it "does not run a query while reporting a bad scope" do
      define_query("Bad") do
        schema do
          count :accounts, from: Account, scope: ->(_) { Order.all }
        end
      end

      statements = nil
      expect do
        statements = SqlCounter.capture { Bad.to_sql }
      end.to raise_error(Pluckr::ConfigurationError, /got a relation for Order/)

      expect(statements).to be_nil
    end
  end
end
