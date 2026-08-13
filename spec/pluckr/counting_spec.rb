# frozen_string_literal: true

RSpec.describe "questions about the root rows" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }
  let!(:other) { User.create!(email: "other@example.com", active: false) }

  before do
    define_query("UserSummary") do
      source User

      schema do
        field :id
        field :email

        one :subscription do
          field :name
        end

        count :videos
      end
    end
  end

  describe "count" do
    it "counts in the database, without building result objects" do
      expect(Pluckr::Result::Builder).not_to receive(:new)

      count = nil
      statements = SqlCounter.capture { count = UserSummary.count }

      expect(count).to eq(2)
      expect(statements.size).to eq(1)
      expect(statements.first).to match(/COUNT/i)
    end

    it "compiles none of the schema - no correlated subquery, no join" do
      sql = SqlCounter.capture { UserSummary.count }.first

      expect(sql).not_to include("videos")
      expect(sql).not_to include("subscriptions")
      expect(sql).not_to match(/JOIN/i)
    end

    it "applies the conditions of the chain" do
      expect(UserSummary.where(active: true).count).to eq(1)
      expect(UserSummary.where.not(active: true).count).to eq(1)
    end

    it "answers `size` the same way, in the database" do
      statements = SqlCounter.capture { expect(UserSummary.all.size).to eq(2) }

      expect(statements.size).to eq(1)
      expect(statements.first).to match(/COUNT/i)
    end

    it "counts a column, skipping its NULLs" do
      User.create!(email: "third@example.com", region_code: nil)

      expect(UserSummary.count(:email)).to eq(3)
      expect(UserSummary.count(:region_code)).to eq(0)
    end

    it "counts within a limit, like ActiveRecord does" do
      expect(UserSummary.limit(1).count).to eq(1)
      expect(UserSummary.offset(1).count).to eq(1)
    end

    it "returns zero rather than nil when nothing matches" do
      expect(UserSummary.where(email: "nobody@example.com").count).to eq(0)
    end

    it "sends a block back to Enumerable, over the results and not the records" do
      expect(UserSummary.all.count { |row| row.email.start_with?("user") }).to eq(1)
      expect(UserSummary.all.count { |row| row.videos_count.zero? }).to eq(2)
    end

    it "needs a source, like every other root query" do
      define_query("Dashboard") do
        schema { count :users, from: User }
      end

      expect { Dashboard.count }.to raise_error(Pluckr::MissingSource)
    end
  end

  describe "exists?" do
    it "asks the database instead of fetching everything" do
      statements = SqlCounter.capture { expect(UserSummary.exists?).to be(true) }

      expect(statements.size).to eq(1)
      expect(statements.first).not_to match(/COUNT/i)
      expect(statements.first).not_to include("videos")
    end

    it "takes conditions, like ActiveRecord" do
      expect(UserSummary.exists?(email: "user@example.com")).to be(true)
      expect(UserSummary.exists?(email: "nobody@example.com")).to be(false)
    end

    it "takes a primary key, like ActiveRecord" do
      expect(UserSummary.exists?(user.id)).to be(true)
      expect(UserSummary.exists?(user.id + 10_000)).to be(false)
    end

    it "applies the conditions of the chain" do
      expect(UserSummary.where(active: true).exists?).to be(true)
      expect(UserSummary.where(active: true).exists?(email: other.email)).to be(false)
    end

    it "backs any?, none? and empty?" do
      relation = UserSummary.where(active: true)

      expect(relation.any?).to be(true)
      expect(relation.none?).to be(false)
      expect(relation.empty?).to be(false)
    end

    it "reports an empty chain as empty, without fetching it" do
      empty = UserSummary.where(email: "nobody@example.com")

      statements = SqlCounter.capture do
        expect(empty).to be_empty
        expect(empty.none?).to be(true)
        expect(empty.any?).to be(false)
      end

      expect(statements.size).to eq(3)
      expect(statements).to all(satisfy { |sql| !sql.include?("videos") })
    end

    it "still honours a block, which Enumerable answers over the results" do
      expect(UserSummary.all.any? { |row| row.email == "user@example.com" }).to be(true)
      expect(UserSummary.all.none? { |row| row.email == "ghost@example.com" }).to be(true)
      expect(UserSummary.all.any? { |row| row.videos_count.positive? }).to be(false)
    end

    it "sends an Enumerable pattern back to Enumerable, not to the database" do
      expect(UserSummary.all.any?(Pluckr::Result::Object)).to be(true)
      expect(UserSummary.all.none?(ActiveRecord::Base)).to be(true)
    end

    it "answers all of it on the query itself, not only on a chain" do
      expect(UserSummary.size).to eq(2)
      expect(UserSummary.any?).to be(true)
      expect(UserSummary.none?).to be(false)
      expect(UserSummary.empty?).to be(false)
      expect(UserSummary.first!.id).to eq(user.id)
    end
  end

  describe "find_by" do
    it "returns the first match as a result object" do
      result = UserSummary.find_by(email: "user@example.com")

      expect(result).to be_a(Pluckr::Result::Object)
      expect(result.id).to eq(user.id)
    end

    it "returns nil when nothing matches" do
      expect(UserSummary.find_by(email: "nobody@example.com")).to be_nil
    end

    it "raises from the bang version, and returns the row when there is one" do
      expect(UserSummary.find_by!(email: "user@example.com").id).to eq(user.id)
      expect { UserSummary.find_by!(email: "nobody@example.com") }
        .to raise_error(ActiveRecord::RecordNotFound, /User/)
    end

    it "names what it looked for when it raises" do
      expect { UserSummary.find_by!(email: "nobody@example.com") }
        .to raise_error(ActiveRecord::RecordNotFound, /nobody@example\.com/)
      expect { UserSummary.find_by!("email = ?", "nobody@example.com") }
        .to raise_error(ActiveRecord::RecordNotFound, /email = \?/)
    end

    it "needs a condition, like ActiveRecord" do
      expect { UserSummary.find_by }.to raise_error(ArgumentError)
      expect { UserSummary.find_by! }.to raise_error(ArgumentError)
    end

    it "reads one row, not the whole table" do
      statements = SqlCounter.capture { UserSummary.find_by(email: other.email) }

      expect(statements.size).to eq(1)
      expect(statements.first).to match(/LIMIT/i)
    end

    it "takes everything `where` takes" do
      expect(UserSummary.find_by(active: [true, false], email: user.email).id).to eq(user.id)
      expect(UserSummary.find_by(region_code: nil).id).to eq(user.id)
      expect(UserSummary.find_by("email = ?", other.email).id).to eq(other.id)
    end

    it "narrows a chain instead of replacing it" do
      expect(UserSummary.where(active: true).find_by(email: other.email)).to be_nil
      expect(UserSummary.where(active: false).find_by(email: other.email).id).to eq(other.id)
    end

    it "picks the same row every time - primary key order, like `first`" do
      expect(UserSummary.find_by(active: [true, false]).id).to eq(user.id)
    end

    it "fills in the whole schema, not only the conditions" do
      Subscription.create!(user_id: user.id, name: "pro")

      expect(UserSummary.find_by(email: user.email).subscription.name).to eq("pro")
    end
  end

  describe "explain" do
    it "explains the statement Pluckr runs, not the root relation" do
      expect(UserSummary.explain.inspect).to include("videos")
    end

    it "explains the chain it is called on" do
      output = UserSummary.where(active: true).limit(1).explain.inspect

      expect(output).to include("videos")
      expect(output).not_to be_empty
    end

    it "builds no result objects" do
      expect(Pluckr::Result::Builder).not_to receive(:new)

      UserSummary.explain.inspect
    end

    it "is not a Pluckr statement, so it publishes no fetch.pluckr event" do
      captured = []
      subscriber = ActiveSupport::Notifications.subscribe("fetch.pluckr") { captured << 1 }
      UserSummary.explain.inspect
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(captured).to be_empty
    end

    it "needs a source" do
      define_query("Dashboard") do
        schema { count :users, from: User }
      end

      expect { Dashboard.explain }.to raise_error(Pluckr::MissingSource)
    end
  end
end
