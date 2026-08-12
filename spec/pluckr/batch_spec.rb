# frozen_string_literal: true

RSpec.describe Pluckr::Batch do
  let!(:user) { User.create!(email: "user@example.com") }
  let!(:other) { User.create!(email: "other@example.com") }

  before do
    Video.create!(user: user, size: 50)
    Video.create!(user: user, size: 250)
    Video.create!(user: other, size: 999)
    Photo.create!(user: user, url: "https://example.com/a.jpg")
    Account.create!(active: true)
    Account.create!(active: false)
  end

  describe "the documented example" do
    subject(:stats) do
      Pluckr.batch do |b|
        b.count user.videos, as: :video_count
        b.sum user.videos.where(size: 100..), :size, as: :big_video_bytes
        b.exists user.photos, as: :has_photos
        b.count Account.active, as: :active_accounts
      end
    end

    it "answers every entry" do
      expect(stats.video_count).to eq(2)
      expect(stats.big_video_bytes).to eq(250)
      expect(stats.has_photos).to be(true)
      expect(stats.active_accounts).to eq(1)
    end

    it "returns one frozen result object" do
      expect(stats).to be_a(Pluckr::Result::Object)
      expect(stats).to be_frozen
      expect(stats.to_h).to eq(
        video_count: 2, big_video_bytes: 250, has_photos: true, active_accounts: 1
      )
    end

    it "runs as a single statement" do
      expect(SqlCounter.capture { stats }.size).to eq(1)
    end
  end

  describe "relations are used as ActiveRecord built them" do
    it "keeps the association's binding, so entries stay per-record" do
      result = Pluckr.batch do |b|
        b.count user.videos, as: :mine
        b.count other.videos, as: :theirs
      end

      expect(result.mine).to eq(2)
      expect(result.theirs).to eq(1)
    end

    it "keeps a named scope" do
      expect(Pluckr.batch { |b| b.count Account.active, as: :n }.n).to eq(1)
    end

    it "keeps a default_scope" do
      Comment.create!(user: user, body: nil)
      Comment.create!(user: user, body: "hello")

      # ArchivedComment has `default_scope { where(body: nil) }`, which the
      # schema DSL refuses to compile. Here ActiveRecord applied it already.
      expect(Pluckr.batch { |b| b.count ArchivedComment.all, as: :archived }.archived).to eq(1)
    end

    it "keeps an STI type condition" do
      Report.create!(user: user, title: "Q1")
      Document.create!(user: user, title: "notes")

      result = Pluckr.batch do |b|
        b.count Report.all, as: :reports
        b.count Document.all, as: :documents
      end

      expect(result.reports).to eq(1)
      expect(result.documents).to eq(2)
    end

    it "keeps joins and merged conditions" do
      result = Pluckr.batch do |b|
        b.count Video.joins(:user).where(users: { email: "user@example.com" }), as: :mine
      end

      expect(result.mine).to eq(2)
    end

    it "keeps a polymorphic association's type condition" do
      photo = Photo.first
      Like.create!(likeable: photo)
      Like.create!(likeable: user)

      result = Pluckr.batch do |b|
        b.count photo.likes, as: :photo_likes
        b.count user.likes, as: :user_likes
      end

      expect(result.photo_likes).to eq(1)
      expect(result.user_likes).to eq(1)
    end

    it "keeps limit, offset and group, because each entry is a derived table" do
      result = Pluckr.batch do |b|
        b.count user.videos.limit(1), as: :capped
        b.count Video.group(:user_id), as: :users_with_videos
        b.count Video.order(:size).offset(1), as: :after_first
      end

      expect(result.capped).to eq(1)
      expect(result.users_with_videos).to eq(2)
      expect(result.after_first).to eq(2)
      expect(result.to_h.values).to all(be_a(Integer))
    end

    it "ignores select and order noise" do
      result = Pluckr.batch do |b|
        b.count user.videos.select(:id).order(:size), as: :videos
        b.sum user.videos.select(:id), :size, as: :bytes
      end

      expect(result.videos).to eq(2)
      expect(result.bytes).to eq(300)
    end

    it "ignores eager loading" do
      result = Pluckr.batch { |b| b.count Video.includes(:user), as: :videos }

      expect(result.videos).to eq(3)
    end

    it "keeps the projection DISTINCT applies to" do
      Video.create!(user: user, size: 50) # user now has sizes 50, 250, 50

      relation = Video.where(user_id: user.id).select(:size).distinct
      result = Pluckr.batch do |b|
        b.count relation, as: :distinct_sizes
        b.count Video.where(user_id: user.id).distinct, as: :distinct_rows
      end

      expect(result.distinct_sizes).to eq(2)
      expect(result.distinct_sizes).to eq(relation.count) # same answer as ActiveRecord
      expect(result.distinct_rows).to eq(3)
    end

    it "keeps a has_many :through, which the schema DSL refuses to compile" do
      Like.create!(likeable: Photo.first)
      Like.create!(likeable: Photo.first)
      Like.create!(likeable: user)

      expect(Pluckr.batch { |b| b.count user.photo_likes, as: :likes }.likes).to eq(2)

      expect do
        Class.new(Pluckr::Query) do
          source User
          schema { count :photo_likes }
        end
      end.to raise_error(Pluckr::UnsupportedAssociation, /:through/)
    end

    it "handles a none relation" do
      expect(Pluckr.batch { |b| b.count Video.none, as: :nothing }.nothing).to eq(0)
    end

    it "drops a row lock, which cannot sit under an aggregate" do
      result = Pluckr.batch { |b| b.count User.all.lock, as: :users }

      expect(result.users).to eq(2)
    end
  end

  describe "operations" do
    it "averages, answering what ActiveRecord answers" do
      result = Pluckr.batch do |b|
        b.avg user.videos, :size, as: :mean
        b.average user.videos, :size, as: :mean_alias
        b.avg Video.none, :size, as: :empty
      end

      expect(result.mean).to be_a(BigDecimal)
      expect(result.mean).to eq(user.videos.average(:size))
      expect(result.mean_alias).to eq(result.mean)
      expect(result.empty).to be_nil
    end

    it "supports count, sum, min, max and exists" do
      result = Pluckr.batch do |b|
        b.count user.videos, as: :count
        b.sum user.videos, :size, as: :total
        b.min user.videos, :size, as: :smallest
        b.max user.videos, :size, as: :largest
        b.exists user.videos, as: :any
        b.exists user.comments, as: :any_comments
      end

      expect(result.to_h).to eq(
        count: 2, total: 300, smallest: 50, largest: 250, any: true, any_comments: false
      )
    end

    it "counts a specific column, skipping NULLs" do
      Video.create!(user: user, size: nil)

      result = Pluckr.batch do |b|
        b.count user.videos, as: :all_videos
        b.count user.videos, :size, as: :sized_videos
      end

      expect(result.all_videos).to eq(3)
      expect(result.sized_videos).to eq(2)
    end

    it "accepts a model class as well as a relation" do
      expect(Pluckr.batch { |b| b.count User, as: :users }.users).to eq(2)
    end

    it "returns zero for a sum over no rows, like ActiveRecord" do
      expect(Pluckr.batch { |b| b.sum Order.all, :amount, as: :revenue }.revenue).to eq(0)
      expect(Order.all.sum(:amount)).to eq(0)
    end

    it "returns nil for a min or max over no rows" do
      result = Pluckr.batch do |b|
        b.min Order.all, :amount, as: :smallest
        b.max Order.all, :amount, as: :largest
      end

      expect(result.smallest).to be_nil
      expect(result.largest).to be_nil
    end

    it "returns zero for a count over no rows" do
      expect(Pluckr.batch { |b| b.count Order.all, as: :orders }.orders).to eq(0)
    end

    it "casts values the same way on every adapter" do
      result = Pluckr.batch do |b|
        b.exists user.videos, as: :flag
        b.count user.videos, as: :number
        b.max user.videos, :size, as: :biggest
        b.max User.all, :created_at, as: :last_signup
      end

      expect(result.flag).to be(true)
      expect(result.number).to be_a(Integer)
      expect(result.biggest).to be_a(Integer)
      expect(result.last_signup).to be_a(Time)
    end
  end

  describe "to_sql" do
    subject(:batch) do
      described_class.build do |b|
        b.count user.videos, as: :video_count
        b.exists user.photos, as: :has_photos
      end
    end

    it "is available without executing anything" do
      sql = nil

      expect(SqlCounter.capture { sql = batch.to_sql }).to be_empty
      expect(sql).to start_with("SELECT ")
      expect(sql).to include("COUNT(*)", "EXISTS")
    end

    it "wraps each relation in its own derived table" do
      expect(batch.to_sql).to include(qt(:pluckr_batch_1), qt(:pluckr_batch_2))
    end

    it "quotes values, never interpolates them" do
      hostile = "x' OR 1=1 --"
      sql = described_class.build { |b| b.count User.where(email: hostile), as: :n }.to_sql

      expect(sql).to include(qv(hostile))
      expect(Pluckr.batch { |b| b.count User.where(email: hostile), as: :n }.n).to eq(0)
    end

    it "picks up entries added after the first compile" do
      batch = described_class.build { |b| b.count User.all, as: :users }
      expect(batch.to_sql).not_to include("videos")

      batch.count Video.all, as: :videos

      expect(batch.to_sql).to include(qt(:videos))
      expect(batch.fetch.to_h).to eq(users: 2, videos: 3)
    end

    it "can be fetched more than once, re-reading the data" do
      batch = described_class.build { |b| b.count User.all, as: :users }

      expect(batch.fetch.users).to eq(2)
      User.create!(email: "third@example.com")
      expect(batch.fetch.users).to eq(3)
    end

    it "lists its entries" do
      expect(batch.entries).to eq(%i[video_count has_photos])
      expect(batch.inspect).to eq("#<Pluckr::Batch video_count, has_photos>")
    end
  end

  describe "errors" do
    it "rejects a missing block" do
      expect { Pluckr.batch }.to raise_error(Pluckr::ConfigurationError, /requires a block/)
    end

    it "rejects an empty batch" do
      expect { Pluckr.batch { |_b| nil } }
        .to raise_error(Pluckr::ConfigurationError, /batch is empty/)
    end

    it "rejects something that is not a relation" do
      expect { Pluckr.batch { |b| b.count [1, 2, 3], as: :n } }
        .to raise_error(Pluckr::ConfigurationError, /expects an ActiveRecord relation or model/)
    end

    it "rejects an unknown column" do
      expect { Pluckr.batch { |b| b.sum user.videos, :nope, as: :n } }
        .to raise_error(Pluckr::UnknownField, "Video does not have column `nope`")
    end

    it "requires a column for sum, min and max" do
      expect { Pluckr.batch { |b| b.sum user.videos, as: :n } }.to raise_error(ArgumentError)
    end

    it "requires an output name" do
      expect { Pluckr.batch { |b| b.count user.videos } }.to raise_error(ArgumentError, /:as/)
    end

    it "rejects sum/min/max over a grouped relation" do
      expect { Pluckr.batch { |b| b.sum Video.group(:user_id), :size, as: :n } }
        .to raise_error(Pluckr::ConfigurationError, /relation is grouped/)

      expect { Pluckr.batch { |b| b.count Video.group(:user_id), :size, as: :n } }
        .to raise_error(Pluckr::ConfigurationError, /relation is grouped/)
    end

    it "rejects an aggregate column that DISTINCT projected away" do
      expect { Pluckr.batch { |b| b.sum Video.select(:id).distinct, :size, as: :n } }
        .to raise_error(Pluckr::ConfigurationError, /not available to aggregate/)
    end

    it "rejects an unsupported operation at the AST level" do
      expect { Pluckr::Schema::Aggregate.new(output: :x, operation: :median, model: User) }
        .to raise_error(Pluckr::ConfigurationError, /unsupported aggregate operation/)
    end

    it "rejects duplicate output names" do
      expect do
        Pluckr.batch do |b|
          b.count user.videos, as: :n
          b.count user.photos, as: :n
        end
      end.to raise_error(Pluckr::ConfigurationError, /duplicate output name `n`/)
    end

    it "rejects relations from different connections" do
      stub_const("Elsewhere", Class.new(ActiveRecord::Base) { self.table_name = "users" })
      allow(Elsewhere).to receive(:connection_pool).and_return(Object.new)

      expect do
        Pluckr.batch do |b|
          b.count User.all, as: :here
          b.count Elsewhere.all, as: :there
        end
      end.to raise_error(Pluckr::ConfigurationError, /different database connections/)
    end

    it "raises NoMethodError for an entry that was not requested" do
      result = Pluckr.batch { |b| b.count user.videos, as: :videos }

      expect { result.photos }.to raise_error(NoMethodError)
    end
  end
end
