# frozen_string_literal: true

RSpec.describe "first and last" do
  let!(:user) { User.create!(email: "user@example.com") }
  let!(:oldest) { Comment.create!(user: user, body: "oldest", created_at: 3.days.ago) }
  let!(:middle) { Comment.create!(user: user, body: "middle", created_at: 2.days.ago) }
  let!(:newest) { Comment.create!(user: user, body: "newest", created_at: 1.day.ago) }

  describe "defaults" do
    before do
      define_query("UserSummary") do
        source User

        schema do
          field :email

          last :comment, via: :comments do
            field :id
            field :body
          end

          first :earliest_comment, via: :comments do
            field :body
          end
        end
      end
    end

    it "picks by primary key, the way ActiveRecord does" do
      result = UserSummary.find(user.id)

      expect(result.comment.body).to eq(user.comments.last.body)
      expect(result.comment.id).to eq(newest.id)
      expect(result.earliest_comment.body).to eq(user.comments.first.body)
    end

    it "nests in to_h" do
      expect(UserSummary.find(user.id).to_h).to eq(
        email: "user@example.com",
        comment: { id: newest.id, body: "newest" },
        earliest_comment: { body: "oldest" }
      )
    end

    it "is nil when the collection is empty" do
      empty = User.create!(email: "empty@example.com")

      expect(UserSummary.find(empty.id).comment).to be_nil
      expect(UserSummary.find(empty.id).earliest_comment).to be_nil
    end

    it "returns an object when the row exists but the selected column is NULL" do
      other = User.create!(email: "other@example.com")
      Comment.create!(user: other, body: nil)

      picked = UserSummary.find(other.id).comment

      expect(picked).not_to be_nil
      expect(picked.body).to be_nil
    end

    it "does not multiply root rows" do
      User.create!(email: "second@example.com").tap do |second|
        3.times { |i| Comment.create!(user: second, body: "c#{i}") }
      end

      results = nil
      statements = SqlCounter.capture { results = UserSummary.order(:id).fetch }

      expect(statements.size).to eq(1)
      expect(results.size).to eq(2)
      expect(results.map { |row| row.comment.body }).to eq(%w[newest c2])
    end

    it "compiles to correlated subqueries, not a join" do
      sql = UserSummary.to_sql

      expect(sql).not_to include("JOIN")
      expect(sql).to include("ORDER BY", "LIMIT 1")
    end
  end

  describe "order:" do
    it "accepts a column name" do
      define_query("UserSummary") do
        source User

        schema do
          first :earliest, via: :comments, order: :created_at do
            field :body
          end

          last :latest, via: :comments, order: :created_at do
            field :body
          end
        end
      end

      result = UserSummary.find(user.id)

      expect(result.earliest.body).to eq("oldest")
      expect(result.latest.body).to eq("newest")
    end

    it "takes the final row of the given order, like relation.order(...).last" do
      define_query("UserSummary") do
        source User

        schema do
          last :comment, via: :comments, order: { created_at: :asc } do
            field :body
          end

          first :other, via: :comments, order: { created_at: :desc } do
            field :body
          end
        end
      end

      result = UserSummary.find(user.id)

      expect(result.comment.body).to eq(user.comments.order(created_at: :asc).last.body)
      expect(result.comment.body).to eq("newest")
      expect(result.other.body).to eq(user.comments.order(created_at: :desc).first.body)
    end

    it "accepts several columns" do
      define_query("UserSummary") do
        source User

        schema do
          first :comment, via: :comments, order: [{ body: :asc }, { created_at: :desc }] do
            field :body
          end
        end
      end

      expect(UserSummary.find(user.id).comment.body)
        .to eq(user.comments.order(body: :asc, created_at: :desc).first.body)
    end

    it "breaks ties on the primary key, so every column comes from one row" do
      tied_at = 1.hour.ago
      first_tie = Comment.create!(user: user, body: "tie-a", created_at: tied_at)
      second_tie = Comment.create!(user: user, body: "tie-b", created_at: tied_at)

      define_query("UserSummary") do
        source User

        schema do
          last :comment, via: :comments, order: :created_at do
            field :id
            field :body
          end
        end
      end

      picked = UserSummary.find(user.id).comment

      expect([first_tie.id, second_tie.id]).to include(picked.id)
      expect(picked.id).to eq(second_tie.id) # highest primary key wins the tie
      expect(picked.body).to eq(Comment.find(picked.id).body)
    end
  end

  describe "in context" do
    it "works inside a nested one" do
      boss = User.create!(email: "boss@example.com")
      Comment.create!(user: boss, body: "boss comment")
      user.update!(manager: boss)

      define_query("UserSummary") do
        source User

        schema do
          one :manager do
            field :email

            last :comment, via: :comments do
              field :body
            end
          end
        end
      end

      expect(UserSummary.find(user.id).manager.comment.body).to eq("boss comment")
    end

    it "respects an STI type condition" do
      Report.create!(user: user, title: "Q1")
      Document.create!(user: user, title: "notes")

      define_query("UserDocs") do
        source User

        schema do
          last :report, via: :reports do
            field :title
          end

          last :document, via: :documents do
            field :title
          end
        end
      end

      result = UserDocs.find(user.id)

      expect(result.report.title).to eq("Q1")
      expect(result.document.title).to eq("notes")
    end

    it "respects a polymorphic type condition" do
      photo = Photo.create!(user: user, url: "https://example.com/a.jpg")
      Like.create!(likeable: user)
      photo_like = Like.create!(likeable: photo)

      define_query("PhotoSummary") do
        source Photo

        schema do
          last :like, via: :likes do
            field :id
          end
        end
      end

      expect(PhotoSummary.find(photo.id).like.id).to eq(photo_like.id)
    end

    it "aliases fields like anywhere else" do
      define_query("UserSummary") do
        source User

        schema do
          last :comment, via: :comments do
            field :body, as: :text
            field :created_at, as: :at
          end
        end
      end

      picked = UserSummary.find(user.id).comment

      expect(picked.text).to eq("newest")
      expect(picked.at).to be_a(Time)
    end

    it "works alongside a singular association and aggregates" do
      Subscription.create!(user: user, name: "Pro")

      define_query("UserSummary") do
        source User

        schema do
          field :id

          one :subscription do
            field :name
          end

          last :comment, via: :comments do
            field :body
          end

          count :comments
          exists :photos
        end
      end

      result = nil
      statements = SqlCounter.capture { result = UserSummary.find(user.id) }

      expect(statements.size).to eq(1)
      expect(result.to_h).to eq(
        id: user.id,
        subscription: { name: "Pro" },
        comment: { body: "newest" },
        comments_count: 3,
        photos_exists: false
      )
    end

    it "picks from a singular association too" do
      Subscription.create!(user: user, name: "Pro")

      define_query("UserSummary") do
        source User

        schema do
          last :subscription do
            field :name
          end
        end
      end

      expect(UserSummary.find(user.id).subscription.name).to eq("Pro")
    end
  end

  describe "errors" do
    it "requires a block" do
      expect do
        define_query("Bad") do
          source User

          schema { last :comment, via: :comments }
        end
      end.to raise_error(Pluckr::ConfigurationError, /requires a block/)
    end

    it "rejects an empty block" do
      expect do
        define_query("Bad") do
          source User

          schema { last(:comment, via: :comments) { nil } }
        end
      end.to raise_error(Pluckr::ConfigurationError, /`last :comment` block is empty/)
    end

    it "rejects anything but fields inside" do
      expect do
        define_query("Bad") do
          source User

          schema do
            last :comment, via: :comments do
              field :body
              exists :user
            end
          end
        end
      end.to raise_error(Pluckr::ConfigurationError, /can only contain `field`/)
    end

    it "rejects a nested association inside" do
      expect do
        define_query("Bad") do
          source User

          schema do
            last :comment, via: :comments do
              one :user do
                field :email
              end
            end
          end
        end
      end.to raise_error(Pluckr::ConfigurationError, /can only contain `field`/)
    end

    it "rejects an unknown association" do
      expect do
        define_query("Bad") do
          source User

          schema { last(:nope) { field :id } }
        end
      end.to raise_error(Pluckr::UnknownAssociation)
    end

    it "rejects an unknown order column" do
      expect do
        define_query("Bad") do
          source User

          schema { last(:comment, via: :comments, order: :nope) { field :body } }
        end
      end.to raise_error(Pluckr::UnknownField, "Comment does not have column `nope`")
    end

    it "rejects an unknown order direction" do
      expect do
        define_query("Bad") do
          source User

          schema { last(:comment, via: :comments, order: { created_at: :sideways }) { field :body } }
        end
      end.to raise_error(Pluckr::ConfigurationError, /expects :asc or :desc/)
    end

    it "rejects an order that is not a column, Hash or Array" do
      expect do
        define_query("Bad") do
          source User

          schema { last(:comment, via: :comments, order: 42) { field :body } }
        end
      end.to raise_error(Pluckr::ConfigurationError, /expects a column, a Hash or an Array/)
    end

    it "needs a source" do
      expect do
        define_query("Bad") do
          schema { last(:comment, via: :comments) { field :body } }
        end
      end.to raise_error(Pluckr::MissingSource)
    end
  end
end
