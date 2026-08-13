# frozen_string_literal: true

RSpec.describe "reading one end of a chain" do
  let!(:first_user) { User.create!(email: "a@example.com", active: true) }
  let!(:middle_user) { User.create!(email: "b@example.com", active: false) }
  let!(:last_user) { User.create!(email: "c@example.com", active: true) }

  before do
    define_query("UserSummary") do
      source User

      schema do
        field :id
        field :email
        count :videos
      end
    end
  end

  describe "first" do
    it "reads one row, in primary key order" do
      statements = SqlCounter.capture { expect(UserSummary.first.email).to eq("a@example.com") }

      expect(statements.size).to eq(1)
      expect(statements.first).to match(/LIMIT/i)
    end

    it "takes a count, like ActiveRecord" do
      expect(UserSummary.first(2).map(&:email)).to eq(%w[a@example.com b@example.com])
    end

    it "asks the database for exactly that many rows" do
      sql = SqlCounter.capture { UserSummary.first(2) }.first

      expect(sql).to match(/LIMIT/i)
      expect(sql).not_to match(/LIMIT\D+1\b/i)
    end

    it "follows an order of its own when there is one" do
      expect(UserSummary.order(email: :desc).first.email).to eq("c@example.com")
    end

    it "cannot read past a page the chain already limits" do
      expect(UserSummary.order(:id).limit(2).first(5).map(&:email))
        .to eq(User.order(:id).limit(2).first(5).map(&:email))
      expect(UserSummary.order(:id).limit(2).first(5).size).to eq(2)
      expect(UserSummary.limit(0).first).to be_nil
      expect(UserSummary.limit(0).first(3)).to eq([])
    end

    it "raises from the bang version when there is nothing" do
      expect(UserSummary.where(email: "nobody@example.com").first).to be_nil
      expect { UserSummary.where(email: "nobody@example.com").first! }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "last" do
    it "reads one row from the other end, without hydrating the chain" do
      result = nil
      statements = SqlCounter.capture { result = UserSummary.last }

      expect(result.email).to eq("c@example.com")
      expect(statements.size).to eq(1)
      expect(statements.first).to match(/DESC/i)
      expect(statements.first).to match(/LIMIT/i)
    end

    it "takes a count, and returns it in the chain's own order" do
      expect(UserSummary.last(2).map(&:email)).to eq(%w[b@example.com c@example.com])
    end

    it "reverses an order of its own, like ActiveRecord does" do
      expect(UserSummary.order(email: :desc).last.email).to eq("a@example.com")
      expect(UserSummary.order(email: :desc).last(2).map(&:email)).to eq(%w[b@example.com a@example.com])
    end

    it "applies the conditions of the chain" do
      expect(UserSummary.where(active: true).last.email).to eq("c@example.com")
    end

    it "reverses the orders ActiveRecord accepts, not only symbols" do
      expect(UserSummary.order(User.arel_table[:email].desc).last.email).to eq("a@example.com")
      expect(UserSummary.order("email DESC").last.email).to eq("a@example.com")
      expect(UserSummary.order(:active, :email).last(2).map(&:email)).to eq(%w[a@example.com c@example.com])
    end

    it "takes the last row of a page the chain already limits, not of the table" do
      # ActiveRecord reads the page and takes its tail rather than replacing the
      # caller's `limit` with its own - the same override `find_each` refuses.
      expect(UserSummary.order(:id).limit(2).last.email).to eq("b@example.com")
      expect(UserSummary.order(:id).limit(2).last.email).to eq(User.order(:id).limit(2).last.email)
    end

    it "does the same for an offset, and for a count" do
      expect(UserSummary.order(:id).offset(1).last.email).to eq(User.order(:id).offset(1).last.email)
      expect(UserSummary.order(:id).limit(2).last(2).map(&:email))
        .to eq(User.order(:id).limit(2).last(2).map(&:email))
      expect(UserSummary.order(:id).limit(2).last(5).map(&:email)).to eq(%w[a@example.com b@example.com])
    end

    it "works for a composite primary key, which needs no lookup" do
      plan = Plan.create!(name: "Pro")
      Membership.create!(user_id: first_user.id, plan_id: plan.id, role: "owner")

      define_query("MembershipSummary") do
        source Membership

        schema { field :role }
      end

      expect(MembershipSummary.last.role).to eq("owner")
    end

    it "is nil when nothing matches, and raises from the bang version" do
      expect(UserSummary.where(email: "nobody@example.com").last).to be_nil
      expect { UserSummary.where(email: "nobody@example.com").last! }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "take" do
    it "reads rows without an order, one statement, no hydrating" do
      results = nil
      statements = SqlCounter.capture { results = UserSummary.take(2) }

      expect(results.size).to eq(2)
      expect(statements.size).to eq(1)
      expect(statements.first).to match(/LIMIT/i)
    end

    it "returns one result object without a count, like ActiveRecord" do
      expect(UserSummary.take).to be_a(Pluckr::Result::Object)
      expect(UserSummary.take(1)).to be_an(Array)
    end

    it "is nil when nothing matches, and raises from the bang version" do
      expect(UserSummary.where(email: "nobody@example.com").take).to be_nil
      expect { UserSummary.where(email: "nobody@example.com").take! }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "one? and many?" do
    it "asks the database for two rows, not for all of them" do
      expect(Pluckr::Result::Builder).not_to receive(:new)

      statements = SqlCounter.capture do
        expect(UserSummary.many?).to be(true)
        expect(UserSummary.one?).to be(false)
      end

      expect(statements.size).to eq(2)
      expect(statements).to all(match(/COUNT/i))
      expect(statements).to all(satisfy { |sql| !sql.include?("videos") })
    end

    it "counts the rows of the chain" do
      expect(UserSummary.where(email: "a@example.com").one?).to be(true)
      expect(UserSummary.where(email: "a@example.com").many?).to be(false)
      expect(UserSummary.where(email: "nobody@example.com").one?).to be(false)
    end

    it "never widens a limit of the chain's own to reach an answer" do
      expect(UserSummary.limit(1).many?).to be(false)
      expect(UserSummary.limit(1).one?).to be(true)
      expect(UserSummary.limit(3).one?).to be(false)
      expect(UserSummary.limit(3).many?).to be(true)
      expect(UserSummary.offset(2).one?).to be(true)
    end

    it "answers exactly what ActiveRecord answers for the same chain" do
      [User.all, User.limit(1), User.limit(3), User.offset(2), User.where(active: true)]
        .zip([UserSummary.all, UserSummary.limit(1), UserSummary.limit(3),
              UserSummary.offset(2), UserSummary.where(active: true)]) do |records, results|
        expect([results.one?, results.many?]).to eq([records.one?, records.many?])
      end
    end

    it "sends a block or a pattern back to Enumerable" do
      expect(UserSummary.all.one? { |row| row.email == "a@example.com" }).to be(true)
      expect(UserSummary.all.many? { |row| row.email.end_with?("@example.com") }).to be(true)
      expect(UserSummary.all.one?(Pluckr::Result::Object)).to be(false)
    end
  end

  describe "find" do
    it "still looks up by primary key" do
      expect(UserSummary.find(middle_user.id).email).to eq("b@example.com")
      expect { UserSummary.find(0) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "sends a block to Enumerable, like ActiveRecord does" do
      found = UserSummary.all.find { |row| row.email == "c@example.com" }

      expect(found.id).to eq(last_user.id)
      expect(UserSummary.all.find { |row| row.email == "nobody@example.com" }).to be_nil
    end

    it "sends it from the query class too, not only from a chain" do
      expect(UserSummary.find { |row| row.email == "c@example.com" }.id).to eq(last_user.id)
      expect(UserSummary.find { |row| row.email == "nobody@example.com" }).to be_nil
    end

    it "needs an id when there is no block" do
      expect { UserSummary.all.find }.to raise_error(ArgumentError)
    end

    it "treats a nil id as a missing record, not as a missing argument" do
      # `find(params[:id])` with no param is a 404 in ActiveRecord, and the
      # controller that rescues RecordNotFound should keep working here.
      expect { UserSummary.find(nil) }
        .to raise_error(ActiveRecord::RecordNotFound, /without an ID/)
    end

    it "reads several ids as an array, in the order they were asked for" do
      expect(UserSummary.find(last_user.id, first_user.id).map(&:email))
        .to eq(%w[c@example.com a@example.com])
      expect(UserSummary.find([first_user.id, last_user.id]).map(&:email))
        .to eq(%w[a@example.com c@example.com])
      expect(UserSummary.find([first_user.id])).to be_an(Array)
    end

    it "raises when one of several ids is missing, like ActiveRecord" do
      expect { UserSummary.find([first_user.id, 0]) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "needs the primary key on the schema for several ids, but not for one" do
      define_query("UserEmail") do
        source User

        schema { field :email }
      end

      expect(UserEmail.find(first_user.id).email).to eq("a@example.com")
      expect { UserEmail.find(first_user.id, last_user.id) }
        .to raise_error(Pluckr::ConfigurationError, /UserEmail needs `field :id`/)
    end

    it "answers what ActiveRecord answers for the same arguments" do
      ids = [first_user.id, last_user.id]

      expect(UserSummary.find(ids).map(&:id)).to eq(User.find(ids).map(&:id))
      expect(UserSummary.find(*ids).map(&:id)).to eq(User.find(*ids).map(&:id))
      expect(UserSummary.find(ids.first).id).to eq(User.find(ids.first).id)
    end
  end
end
