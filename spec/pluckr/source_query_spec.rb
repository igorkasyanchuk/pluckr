# frozen_string_literal: true

RSpec.describe "source-rooted queries" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }

  describe "fields" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          field :email
        end
      end
    end

    it "exposes the source model" do
      expect(UserSummary.source_model).to eq(User)
    end

    it "returns a Pluckr result object, not an ActiveRecord model" do
      result = UserSummary.find(user.id)

      expect(result).to be_a(Pluckr::Result::Object)
      expect(result).not_to be_a(ActiveRecord::Base)
    end

    it "reads the selected fields" do
      result = UserSummary.find(user.id)

      expect(result.id).to eq(user.id)
      expect(result.email).to eq("user@example.com")
    end

    it "selects only the requested columns" do
      sql = UserSummary.to_sql

      expect(sql).to include("#{col(:users, :id)} AS #{q(:id)}", "#{col(:users, :email)} AS #{q(:email)}")
      expect(sql).not_to include("#{qt(:users)}.*")
      expect(sql).not_to include("active")
    end

    it "does not respond to columns that were not selected" do
      expect { UserSummary.find(user.id).active }.to raise_error(NoMethodError)
    end
  end

  describe "field aliases" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          field :email, as: :contact_email
        end
      end
    end

    it "exposes the alias" do
      expect(UserSummary.find(user.id).contact_email).to eq("user@example.com")
    end

    it "does not expose the original name" do
      expect { UserSummary.find(user.id).email }.to raise_error(NoMethodError)
    end

    it "uses the alias in to_h" do
      expect(UserSummary.find(user.id).to_h).to eq(id: user.id, contact_email: "user@example.com")
    end
  end

  describe "one" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id

          one :subscription do
            field :id
            field :name
          end
        end
      end
    end

    it "hydrates a has_one association" do
      subscription = Subscription.create!(user: user, name: "Pro")

      result = UserSummary.find(user.id)

      expect(result.subscription.id).to eq(subscription.id)
      expect(result.subscription.name).to eq("Pro")
    end

    it "returns nil when the association is missing" do
      expect(UserSummary.find(user.id).subscription).to be_nil
    end

    it "returns an object (not nil) when the association exists with NULL columns" do
      Subscription.create!(user: user, name: nil)

      subscription = UserSummary.find(user.id).subscription

      expect(subscription).not_to be_nil
      expect(subscription.name).to be_nil
    end

    it "uses a LEFT OUTER JOIN inferred from reflection" do
      expect(UserSummary.to_sql).to include("LEFT OUTER JOIN")
      expect(UserSummary.to_sql).to include("#{col(:pluckr_subscription, :user_id)} = #{col(:users, :id)}")
    end

    it "nests inside to_h and hides internal aliases" do
      Subscription.create!(user: user, name: "Pro")

      hash = UserSummary.find(user.id).to_h

      expect(hash).to eq(id: user.id, subscription: { id: Subscription.first.id, name: "Pro" })
      expect(hash.keys.map(&:to_s).grep(/__pluckr/)).to be_empty
    end

    it "supports belongs_to from the other side" do
      subscription = Subscription.create!(user: user, name: "Pro")

      define_query("SubscriptionSummary") do
        source Subscription

        schema do
          field :id

          one :user do
            field :email
          end
        end
      end

      expect(SubscriptionSummary.find(subscription.id).user.email).to eq("user@example.com")
    end

    it "rejects has_many associations" do
      expect do
        define_query("Bad") do
          source User

          schema do
            one :photos do
              field :id
            end
          end
        end
      end.to raise_error(
        Pluckr::InvalidAssociation,
        "`User#photos` is a has_many association and cannot be used with `one`"
      )
    end
  end

  describe "one with via:" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id

          one :plan, via: :subscription do
            field :name
          end
        end
      end
    end

    it "names the result after the DSL name and joins the association" do
      Subscription.create!(user: user, name: "Pro")

      result = UserSummary.find(user.id)

      expect(result.plan.name).to eq("Pro")
      expect { result.subscription }.to raise_error(NoMethodError)
    end
  end

  describe "nested one" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id

          one :subscription do
            field :name

            one :plan do
              field :name
            end
          end
        end
      end
    end

    it "walks a chain of singular associations" do
      plan = Plan.create!(name: "Gold")
      Subscription.create!(user: user, plan: plan, name: "Pro")

      result = UserSummary.find(user.id)

      expect(result.subscription.name).to eq("Pro")
      expect(result.subscription.plan.name).to eq("Gold")
      expect(result.to_h).to eq(id: user.id, subscription: { name: "Pro", plan: { name: "Gold" } })
    end

    it "returns nil for a missing leaf association" do
      Subscription.create!(user: user, name: "Pro")

      expect(UserSummary.find(user.id).subscription.plan).to be_nil
    end

    it "returns nil for the whole branch when the parent is missing" do
      expect(UserSummary.find(user.id).subscription).to be_nil
    end
  end

  describe "custom foreign keys" do
    it "resolves has_one with a custom foreign key" do
      Profile.create!(owner: user, nickname: "iggy")

      define_query("UserSummary") do
        source User

        schema do
          field :id

          one :profile do
            field :nickname
          end
        end
      end

      expect(UserSummary.to_sql).to include("#{col(:pluckr_profile, :owner_id)} = #{col(:users, :id)}")
      expect(UserSummary.find(user.id).profile.nickname).to eq("iggy")
    end

    it "resolves belongs_to with a custom foreign key" do
      profile = Profile.create!(owner: user, nickname: "iggy")

      define_query("ProfileSummary") do
        source Profile

        schema do
          field :id

          one :owner do
            field :email
          end
        end
      end

      expect(ProfileSummary.find(profile.id).owner.email).to eq("user@example.com")
    end
  end

  describe "exists" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          exists :photos
          exists :videos, as: :has_videos
        end
      end
    end

    it "is false when there are no associated rows" do
      result = UserSummary.find(user.id)

      expect(result.photos_exists).to be(false)
      expect(result.has_videos).to be(false)
    end

    it "is true when associated rows exist" do
      Photo.create!(user: user)

      expect(UserSummary.find(user.id).photos_exists).to be(true)
    end

    it "compiles to a correlated EXISTS, not a join" do
      sql = UserSummary.to_sql

      expect(sql).to include(
        "EXISTS (SELECT 1 FROM #{aliased_table(:photos, :pluckr_sub_1)} " \
        "WHERE #{col(:pluckr_sub_1, :user_id)} = #{col(:users, :id)} LIMIT 1 OFFSET 0)"
      )
      expect(sql).not_to include("GROUP BY")
      expect(sql).not_to include("JOIN #{qt(:photos)}")
    end

    it "works for singular associations too" do
      define_query("UserFlags") do
        source User

        schema do
          field :id
          exists :subscription
        end
      end

      expect(UserFlags.find(user.id).subscription_exists).to be(false)

      Subscription.create!(user: user, name: "Pro")

      expect(UserFlags.find(user.id).subscription_exists).to be(true)
    end
  end

  describe "count" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          count :videos
          count :photos, as: :number_of_photos
        end
      end
    end

    it "is zero without associated rows" do
      result = UserSummary.find(user.id)

      expect(result.videos_count).to eq(0)
      expect(result.number_of_photos).to eq(0)
    end

    it "counts associated rows" do
      3.times { Video.create!(user: user) }

      expect(UserSummary.find(user.id).videos_count).to eq(3)
    end

    it "does not multiply root rows when several collections are counted" do
      3.times { Video.create!(user: user) }
      2.times { Photo.create!(user: user) }

      results = UserSummary.fetch

      expect(results.size).to eq(1)
      expect(results.first.videos_count).to eq(3)
      expect(results.first.number_of_photos).to eq(2)
    end

    it "compiles to a scalar subquery" do
      sql = UserSummary.to_sql

      expect(sql).to include(
        "(SELECT COUNT(*) FROM #{aliased_table(:videos, :pluckr_sub_1)} " \
        "WHERE #{col(:pluckr_sub_1, :user_id)} = #{col(:users, :id)})"
      )
      expect(sql).not_to include("GROUP BY")
    end

    it "supports correlated sum/avg/min/max" do
      Video.create!(user: user, size: 10)
      Video.create!(user: user, size: 30)

      define_query("UserVideoStats") do
        source User

        schema do
          field :id
          sum :videos, column: :size
          avg :videos, column: :size
          min :videos, column: :size, as: :smallest_video
          max :videos, column: :size, as: :largest_video
        end
      end

      result = UserVideoStats.find(user.id)

      expect(result.videos_sum).to eq(40)
      expect(result.videos_avg).to eq(20)
      expect(result.smallest_video).to eq(10)
      expect(result.largest_video).to eq(30)
    end

    it "answers the same average as ActiveRecord, as a BigDecimal" do
      [100, 150, 175].each { |size| Video.create!(user: user, size: size) }

      define_query("UserVideoStats") do
        source User

        schema do
          average :videos, column: :size, as: :mean_size
          avg :videos, column: :size
        end
      end

      result = UserVideoStats.find(user.id)

      expect(result.mean_size).to be_a(BigDecimal)
      expect(result.mean_size).to eq(user.videos.average(:size))
      expect(result.videos_avg).to eq(result.mean_size) # `average` is an alias of `avg`
    end

    it "returns nil for an average over no rows, like ActiveRecord" do
      define_query("UserVideoStats") do
        source User

        schema { avg :videos, column: :size }
      end

      expect(UserVideoStats.find(user.id).videos_avg).to be_nil
      expect(user.videos.average(:size)).to be_nil
    end
  end

  describe "querying" do
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

    it "filters with where" do
      results = UserSummary.where(active: true).fetch

      expect(results.map(&:id)).to eq([user.id])
    end

    it "orders" do
      results = UserSummary.order(id: :desc).fetch

      expect(results.map(&:id)).to eq([other.id, user.id])
    end

    it "limits and offsets" do
      expect(UserSummary.order(:id).limit(1).fetch.map(&:id)).to eq([user.id])
      expect(UserSummary.order(:id).limit(1).offset(1).fetch.map(&:id)).to eq([other.id])
    end

    it "chains immutably" do
      base = UserSummary.where(active: true)
      chained = base.limit(1)

      expect(base.to_sql).not_to include("LIMIT")
      expect(chained.to_sql).to include("LIMIT 1")
      expect(chained).not_to equal(base)
    end

    it "fetches every row as a result object" do
      results = UserSummary.fetch

      expect(results.size).to eq(2)
      expect(results).to all(be_a(Pluckr::Result::Object))
    end

    it "orders first by primary key, like ActiveRecord" do
      expect(UserSummary.first.id).to eq(User.first.id)
      expect(UserSummary.first.id).to eq(user.id)
      expect(UserSummary.order(id: :desc).first.id).to eq(other.id) # an explicit order wins
    end

    it "qualifies that order, so joins cannot make it ambiguous" do
      define_query("UserWithSubscription") do
        source User

        schema do
          field :id

          one :subscription do
            field :id
          end
        end
      end

      expect(UserWithSubscription.first.id).to eq(user.id)
      expect(UserWithSubscription.all.to_sql).not_to include("ORDER BY")
    end

    it "finds by primary key" do
      expect(UserSummary.find(user.id).email).to eq("user@example.com")
    end

    it "raises RecordNotFound for a missing record" do
      expect { UserSummary.find(0) }.to raise_error(ActiveRecord::RecordNotFound, /User with 'id'=0/)
    end

    it "requires a source for root querying" do
      define_query("Stats") do
        schema do
          count :users, from: User
        end
      end

      expect { Stats.where(active: true) }.to raise_error(Pluckr::MissingSource)
    end
  end
end
