# frozen_string_literal: true

RSpec.describe "edge cases" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }
  let!(:other) { User.create!(email: "other@example.com", active: false) }

  describe "result objects" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          field :email
          field :active

          one :subscription do
            field :name
          end
        end
      end
    end

    it "hashes by value, so results dedupe in a Set" do
      results = [UserSummary.find(user.id), UserSummary.find(user.id), UserSummary.find(other.id)]

      expect(results.uniq.size).to eq(2)
      expect(results.to_set.size).to eq(2)
    end

    it "is not equal to a result of a different query" do
      define_query("UserEmail") do
        source User

        schema { field :email }
      end

      expect(UserSummary.find(user.id)).not_to eq(UserEmail.find(user.id))
    end

    it "cannot be mutated through to_h" do
      result = UserSummary.find(user.id)
      copy = result.to_h

      copy[:email] = "changed"

      expect(result.email).to eq("user@example.com")
    end

    it "distinguishes false from nil" do
      result = UserSummary.find(other.id)

      expect(result.active).to be(false)
      expect(result.subscription).to be_nil
    end

    it "inspects a missing association as nil" do
      expect(UserSummary.find(other.id).inspect).to include("subscription=nil")
    end
  end

  describe "querying" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :id
          field :email
        end
      end
    end

    it "returns nothing past the end of the table" do
      expect(UserSummary.offset(100).fetch).to eq([])
      expect(UserSummary.limit(0).fetch).to eq([])
    end

    it "raises RecordNotFound for an id that is not a number" do
      expect { UserSummary.find("not-an-id") }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "finds within a chain" do
      expect(UserSummary.where(active: true).find(user.id).email).to eq("user@example.com")
      expect { UserSummary.where(active: false).find(user.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "pages stably across calls" do
      third = User.create!(email: "third@example.com")
      page = UserSummary.order(:id).limit(2)

      expect(page.fetch.map(&:id)).to eq(page.fetch.map(&:id))
      expect(page.offset(2).fetch.map(&:id)).to eq([third.id])
    end

    it "accepts an Arel order" do
      expect(UserSummary.order(User.arel_table[:id].desc).fetch.map(&:id)).to eq([other.id, user.id])
    end

    it "accepts where.not, with ActiveRecord's own NAND semantics" do
      conditions = { active: true, email: "nobody@example.com" }

      expect(UserSummary.where.not(conditions).fetch.map(&:id))
        .to eq(User.where.not(conditions).order(:id).pluck(:id))
      expect(UserSummary.where.not(active: true).fetch.map(&:id)).to eq([other.id])
    end

    # Known limitation: `one` joins under an alias, so association-qualified SQL
    # written against the real table name does not resolve.
    it "cannot reference a joined association by its own table name" do
      define_query("UserWithSubscription") do
        source User

        schema do
          field :id

          one :subscription do
            field :name
          end
        end
      end

      expect { UserWithSubscription.where("subscriptions.name = ?", "Pro").fetch }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "aggregates" do
    before do
      Video.create!(user: user, size: 100)
      Video.create!(user: user, size: nil)
      Video.create!(user: user, size: 200)
    end

    it "skips NULLs the way ActiveRecord does" do
      define_query("UserVideos") do
        source User

        schema do
          count :videos
          count :videos, column: :size, as: :sized
          sum :videos, column: :size
          avg :videos, column: :size
        end
      end

      result = UserVideos.find(user.id)

      expect(result.videos_count).to eq(3)
      expect(result.sized).to eq(user.videos.count(:size))
      expect(result.videos_sum).to eq(user.videos.sum(:size))
      expect(result.videos_avg).to eq(user.videos.average(:size))
    end

    it "aggregates a string column" do
      define_query("UserEmails") do
        schema do
          min :first_email, from: User, column: :email
          max :last_email, from: User, column: :email
        end
      end

      stats = UserEmails.fetch

      expect(stats.first_email).to eq(User.minimum(:email))
      expect(stats.last_email).to eq(User.maximum(:email))
    end

    it "counts through a custom foreign key and a renamed association" do
      Profile.create!(owner: user, nickname: "iggy")

      define_query("UserSummary") do
        source User

        schema do
          count :profiles, via: :profile
          exists :has_profile, via: :profile
        end
      end

      result = UserSummary.find(user.id)

      expect(result.profiles_count).to eq(1)
      expect(result.has_profile_exists).to be(true)
    end

    it "answers a polymorphic exists" do
      photo = Photo.create!(user: user, url: "https://example.com/a.jpg")
      Like.create!(likeable: user)

      define_query("PhotoSummary") do
        source Photo

        schema { exists :likes }
      end

      expect(PhotoSummary.find(photo.id).likes_exists).to be(false)

      Like.create!(likeable: photo)

      expect(PhotoSummary.find(photo.id).likes_exists).to be(true)
    end
  end

  describe "shapes" do
    it "handles a wide schema in one statement" do
      Subscription.create!(user: user, name: "Pro")
      Video.create!(user: user)

      define_query("Everything") do
        source User

        schema do
          User.column_names.each { |column| field column, as: :"col_#{column}" }

          one :subscription do
            field :name
          end

          last :comment, via: :comments do
            field :body
          end

          exists :photos
          count :videos
          sum :videos, column: :size
          count :total_users, from: User
        end
      end

      result = nil
      statements = SqlCounter.capture { result = Everything.find(user.id) }

      expect(statements.size).to eq(1)
      expect(result.col_email).to eq("user@example.com")
      expect(result.to_h.keys.size).to eq(User.column_names.size + 6)
    end

    it "reads a source that is an STI child, with a pick" do
      Report.create!(user: user, title: "Q1")
      Report.create!(user: user, title: "Q2")
      Document.create!(user: user, title: "notes")

      define_query("ReportList") do
        source Report

        schema do
          field :title

          one :user do
            field :email
          end
        end
      end

      titles = ReportList.where(user_id: user.id).order(:id).fetch.map(&:title)

      expect(titles).to eq(%w[Q1 Q2])
      expect(ReportList.first.user.email).to eq("user@example.com")
    end

    it "combines a pick with root conditions" do
      Comment.create!(user: user, body: "mine")
      Comment.create!(user: other, body: "theirs")

      define_query("UserFeed") do
        source User

        schema do
          field :email

          last :comment, via: :comments do
            field :body
          end
        end
      end

      results = UserFeed.where(active: true).fetch

      expect(results.size).to eq(1)
      expect(results.first.comment.body).to eq("mine")
    end
  end

  describe "batch" do
    it "batches many entries into one statement" do
      10.times { |i| Video.create!(user: user, size: i * 10) }

      batch = Pluckr::Batch.build do |b|
        5.times { |i| b.count user.videos.where(size: (i * 10)..), as: :"at_least_#{i}" }
        b.sum user.videos, :size, as: :total
        b.avg user.videos, :size, as: :mean
        b.min user.videos, :size, as: :smallest
        b.max user.videos, :size, as: :largest
        b.exists user.videos, as: :any
      end

      result = nil
      statements = SqlCounter.capture { result = batch.fetch }

      expect(statements.size).to eq(1)
      expect(result.at_least_0).to eq(10)
      expect(result.at_least_4).to eq(user.videos.where(size: 40..).count)
      expect(result.total).to eq(user.videos.sum(:size))
      expect(result.mean).to eq(user.videos.average(:size))
      expect(result.any).to be(true)
    end

    it "handles a relation that is distinct, filtered and selected at once" do
      Video.create!(user: user, size: 100)
      Video.create!(user: user, size: 100)
      Video.create!(user: user, size: 200)

      relation = Video.where(user_id: user.id).where(size: 50..).select(:size).distinct

      expect(Pluckr.batch { |b| b.count relation, as: :n }.n).to eq(relation.count)
    end

    it "reads a scope defined on an STI child" do
      Report.create!(user: user, title: "Q1")
      Document.create!(user: user, title: "notes")

      result = Pluckr.batch do |b|
        b.count Report.where(title: "Q1"), as: :q1_reports
        b.exists Document.where(title: "notes"), as: :has_notes
      end

      expect(result.q1_reports).to eq(1)
      expect(result.has_notes).to be(true)
    end
  end
end
