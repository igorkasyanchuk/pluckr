# frozen_string_literal: true

RSpec.describe "query variations" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }

  describe "self-referential associations" do
    let!(:boss) { User.create!(email: "boss@example.com") }

    before { user.update!(manager: boss) }

    it "joins the source table to itself for a singular association" do
      define_query("UserSummary") do
        source User

        schema do
          field :email

          one :manager do
            field :email
          end
        end
      end

      expect(UserSummary.find(user.id).manager.email).to eq("boss@example.com")
      expect(UserSummary.find(boss.id).manager).to be_nil
    end

    it "counts a self-referential has_many without colliding with the root table" do
      define_query("UserSummary") do
        source User

        schema do
          field :email
          count :direct_reports
          exists :direct_reports, as: :manager?
        end
      end

      expect(UserSummary.find(boss.id).direct_reports_count).to eq(1)
      expect(UserSummary.find(boss.id).manager?).to be(true)
      expect(UserSummary.find(user.id).direct_reports_count).to eq(0)
    end
  end

  describe "custom primary keys" do
    let!(:region) { Region.create!(code: "eu-west", title: "Europe") }

    before { user.update!(region_code: "eu-west") }

    it "resolves belongs_to against a non-id primary key" do
      define_query("UserSummary") do
        source User

        schema do
          field :email

          one :region do
            field :title
          end
        end
      end

      expect(UserSummary.to_sql).to include("#{col(:pluckr_region, :code)} = #{col(:users, :region_code)}")
      expect(UserSummary.find(user.id).region.title).to eq("Europe")
    end

    it "uses the custom primary key as the presence marker" do
      define_query("UserSummary") do
        source User

        schema do
          field :email

          one :region do
            field :title
          end
        end
      end

      other = User.create!(email: "nowhere@example.com")

      expect(UserSummary.find(other.id).region).to be_nil
    end

    it "correlates has_many subqueries through the custom key" do
      define_query("RegionSummary") do
        source Region

        schema do
          field :code
          count :users
          exists :users
        end
      end

      result = RegionSummary.find(region.code)

      expect(result.users_count).to eq(1)
      expect(result.users_exists).to be(true)
    end
  end

  describe "custom table names" do
    before { 2.times { |i| Invoice.create!(user: user, cents: 100 * (i + 1)) } }

    it "counts and sums through a model with self.table_name" do
      define_query("UserBilling") do
        source User

        schema do
          field :email
          count :invoices
          sum :invoices, column: :cents, as: :billed_cents
        end
      end

      expect(UserBilling.to_sql).to include(qt(:legacy_invoices))

      result = UserBilling.find(user.id)

      expect(result.invoices_count).to eq(2)
      expect(result.billed_cents).to eq(300)
    end

    it "joins back from the custom table" do
      invoice = Invoice.first

      define_query("InvoiceSummary") do
        source Invoice

        schema do
          field :cents

          one :user do
            field :email
          end
        end
      end

      expect(InvoiceSummary.find(invoice.id).user.email).to eq("user@example.com")
    end
  end

  describe "single table inheritance" do
    before do
      Report.create!(user: user, title: "Q1")
      Document.create!(user: user, title: "notes")
    end

    it "restricts correlated subqueries to the STI type" do
      define_query("UserDocs") do
        source User

        schema do
          count :documents
          count :reports
          exists :reports
        end
      end

      result = UserDocs.find(user.id)

      expect(result.documents_count).to eq(2)
      expect(result.reports_count).to eq(1)
      expect(result.reports_exists).to be(true)
      expect(UserDocs.to_sql).to include(qv("Report"))
    end

    it "applies the type condition to a source query" do
      define_query("ReportList") do
        source Report

        schema { field :title }
      end

      expect(ReportList.fetch.map(&:title)).to eq(["Q1"])
    end
  end

  describe "unsupported associations" do
    it "refuses an association whose model has a default_scope" do
      expect do
        define_query("Bad") do
          source User

          schema { count :archived_comments }
        end
      end.to raise_error(Pluckr::UnsupportedAssociation, /default_scope/)
    end
  end

  describe "deep and repeated nesting" do
    let!(:vendor) { Vendor.create!(name: "Acme") }
    let!(:plan) { Plan.create!(name: "Gold", vendor: vendor) }
    let!(:subscription) { Subscription.create!(user: user, plan: plan, name: "Pro") }

    it "walks three levels of singular associations" do
      define_query("UserSummary") do
        source User

        schema do
          one :subscription do
            field :name

            one :plan do
              field :name

              one :vendor do
                field :name
              end
            end
          end
        end
      end

      expect(UserSummary.find(user.id).subscription.plan.vendor.name).to eq("Acme")
      expect(UserSummary.find(user.id).to_h).to eq(
        subscription: { name: "Pro", plan: { name: "Gold", vendor: { name: "Acme" } } }
      )
    end

    it "correlates exists/count from inside a nested association" do
      Subscription.create!(user: User.create!(email: "second@example.com"), plan: plan, name: "Pro")

      define_query("UserSummary") do
        source User

        schema do
          one :subscription do
            one :plan do
              field :name
              count :subscriptions
              exists :subscriptions
            end
          end
        end
      end

      result = UserSummary.find(user.id).subscription.plan

      expect(result.name).to eq("Gold")
      expect(result.subscriptions_count).to eq(2)
      expect(result.subscriptions_exists).to be(true)
    end

    it "selects the same association twice under different names" do
      define_query("UserSummary") do
        source User

        schema do
          one :subscription do
            field :name
          end

          one :plan, via: :subscription do
            field :id
          end
        end
      end

      result = UserSummary.find(user.id)

      expect(result.subscription.name).to eq("Pro")
      expect(result.plan.id).to eq(subscription.id)
      expect(UserSummary.to_sql.scan("LEFT OUTER JOIN").size).to eq(2)
    end

    it "aliases fields inside a nested association" do
      define_query("UserSummary") do
        source User

        schema do
          one :subscription do
            field :name, as: :label
          end
        end
      end

      expect(UserSummary.find(user.id).subscription.label).to eq("Pro")
    end
  end

  describe "root conditions delegated to ActiveRecord" do
    let!(:other) { User.create!(email: "other@example.com", active: false) }

    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          field :email
        end
      end
    end

    it "accepts arrays" do
      expect(UserSummary.where(id: [user.id, other.id]).fetch.size).to eq(2)
    end

    it "accepts ranges" do
      expect(UserSummary.where(id: user.id..other.id).fetch.size).to eq(2)
    end

    it "accepts nil (IS NULL)" do
      expect(UserSummary.where(region_code: nil).fetch.size).to eq(2)
    end

    it "accepts SQL fragments with binds" do
      results = UserSummary.where("email LIKE ?", "user@%").fetch

      expect(results.map(&:email)).to eq(["user@example.com"])
    end

    it "ands chained conditions" do
      expect(UserSummary.where(active: true).where(email: "user@example.com").fetch.size).to eq(1)
      expect(UserSummary.where(active: true).where(email: "other@example.com").fetch).to be_empty
    end

    it "orders by several columns" do
      sql = UserSummary.order(active: :desc, id: :asc).to_sql

      expect(sql).to include("ORDER BY #{col(:users, :active)} DESC, #{col(:users, :id)} ASC")
      expect(UserSummary.order(active: :desc, id: :asc).fetch.map(&:id)).to eq([user.id, other.id])
    end

    it "offsets without a limit" do
      expect(UserSummary.order(:id).offset(1).fetch.map(&:id)).to eq([other.id])
    end

    it "returns an empty array when nothing matches" do
      expect(UserSummary.where(email: "nobody@example.com").fetch).to eq([])
      expect(UserSummary.where(email: "nobody@example.com").first).to be_nil
    end

    it "finds by a string primary key value" do
      expect(UserSummary.find(user.id.to_s).id).to eq(user.id)
    end
  end

  describe "value casting" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :active
          field :created_at
          count :photos
          exists :photos
        end
      end
    end

    it "returns real booleans, times and integers on every adapter" do
      result = UserSummary.find(user.id)

      expect(result.active).to be(true)
      expect(result.created_at).to be_a(Time)
      expect(result.photos_count).to be_a(Integer)
      expect(result.photos_exists).to be(false)
    end
  end

  describe "independent aggregates" do
    before do
      Order.create!(status: "paid", amount: 100)
      Order.create!(status: "refunded", amount: 20)
      Order.create!(status: nil, amount: 5)
    end

    it "supports arrays, nil and multi-key conditions" do
      define_query("OrderStats") do
        schema do
          count :settled, from: Order, where: { status: %w[paid refunded] }
          count :unknown_status, from: Order, where: { status: nil }
          count :small_paid, from: Order, where: { status: "paid", amount: 100 }
        end
      end

      stats = OrderStats.fetch

      expect(stats.settled).to eq(2)
      expect(stats.unknown_status).to eq(1)
      expect(stats.small_paid).to eq(1)
      expect(OrderStats.to_sql).to include("IS NULL")
    end

    it "returns zero for a sum over no rows" do
      define_query("EmptyStats") do
        schema do
          sum :revenue, from: Order, column: :amount, where: { status: "void" }
        end
      end

      expect(EmptyStats.fetch.revenue).to eq(0)
    end

    it "counts a specific column" do
      define_query("OrderStats") do
        schema do
          count :with_status, from: Order, column: :status
        end
      end

      expect(OrderStats.fetch.with_status).to eq(2)
    end
  end

  describe "polymorphic `as:` associations" do
    let!(:photo) { Photo.create!(user: user, url: "https://example.com/a.jpg") }

    before do
      Like.create!(likeable: photo)
      Like.create!(likeable: photo)
      Like.create!(likeable: user)
    end

    it "matches on the type column, not just the id" do
      define_query("PhotoSummary") do
        source Photo

        schema do
          field :id
          count :likes
          exists :likes
        end
      end

      define_query("UserSummary") do
        source User

        schema do
          count :likes
        end
      end

      expect(PhotoSummary.find(photo.id).likes_count).to eq(2)
      expect(PhotoSummary.find(photo.id).likes_exists).to be(true)
      expect(UserSummary.find(user.id).likes_count).to eq(1)
      expect(PhotoSummary.to_sql).to include(qv("Photo"))
    end
  end

  describe "where.not" do
    let!(:other) { User.create!(email: "other@example.com", active: false) }

    it "negates root conditions" do
      define_query("UserSummary") do
        source User

        schema { field :email }
      end

      expect(UserSummary.where.not(active: true).fetch.map(&:email)).to eq(["other@example.com"])
      expect(UserSummary.where.not(active: true).to_sql).to match(/NOT|!=/)
    end
  end

  describe "runtime scopes" do
    it "re-evaluates scope callables on every compilation" do
      threshold = 100

      define_query("UserVideos") do
        source User

        schema do
          count :videos, as: :big_videos, scope: ->(rel) { rel.where(size: threshold..) }
        end
      end

      Video.create!(user: user, size: 50)
      Video.create!(user: user, size: 500)

      expect(UserVideos.find(user.id).big_videos).to eq(1)

      threshold = 10

      expect(UserVideos.find(user.id).big_videos).to eq(2)
    end
  end

  describe "identifier limits" do
    it "raises instead of letting the database truncate a long alias" do
      long_name = ("a".."z").to_a.join * 4

      define_query("Bad") do
        source User

        schema { field :email, as: long_name.to_sym }
      end

      expect { Bad.to_sql }.to raise_error(Pluckr::ConfigurationError, /identifier limit/)
    end
  end

  describe "empty schema" do
    it "is rejected" do
      expect do
        define_query("Bad") do
          source User

          schema { nil }
        end
      end.to raise_error(Pluckr::ConfigurationError, /empty/)
    end
  end

  describe "compilation reuse" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          exists :photos
          count :videos
        end
      end
    end

    it "produces identical SQL when compiled repeatedly" do
      expect(UserSummary.to_sql).to eq(UserSummary.to_sql)
      expect(UserSummary.where(active: true).to_sql).to include(UserSummary.to_sql.split(" FROM ").first)
    end

    it "keeps separate queries on the same model independent" do
      define_query("UserEmails") do
        source User

        schema { field :email }
      end

      expect(UserEmails.to_sql).not_to include("EXISTS")
      expect(UserSummary.to_sql).to include("EXISTS")
    end

    it "stays a single statement with many nodes" do
      define_query("Everything") do
        source User

        schema do
          field :id
          field :email, as: :contact

          one :subscription do
            field :name

            one :plan do
              field :name
            end
          end

          one :manager do
            field :email
          end

          exists :photos
          exists :videos, as: :has_videos
          count :comments
          count :documents
          sum :videos, column: :size
          count :total_users, from: User
        end
      end

      expect(SqlCounter.capture { Everything.fetch }.size).to eq(1)
    end
  end
end
