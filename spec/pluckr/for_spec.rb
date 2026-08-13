# frozen_string_literal: true

RSpec.describe "Query.for" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }
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

  it "reads one record, like find" do
    expect(UserSummary.for(user).email).to eq("user@example.com")
  end

  it "reads several records in one statement, in input order" do
    results = nil
    statements = SqlCounter.capture { results = UserSummary.for([other, user]) }

    expect(statements.size).to eq(1)
    expect(results.map(&:id)).to eq([other.id, user.id])
    expect(results.map(&:email)).to eq(%w[other@example.com user@example.com])
  end

  it "returns an empty array for an empty collection" do
    expect(UserSummary.for([])).to eq([])
  end

  it "repeats a result when the same record is passed twice" do
    results = UserSummary.for([user, user])

    expect(results.map(&:id)).to eq([user.id, user.id])
  end

  it "raises RecordNotFound when a record is missing" do
    ghost = User.new
    ghost.id = user.id
    user.destroy!

    expect { UserSummary.for(ghost) }.to raise_error(ActiveRecord::RecordNotFound)
    expect { UserSummary.for([ghost]) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "reads a relation without instantiating its rows" do
    results = nil
    statements = SqlCounter.capture do
      results = UserSummary.for(User.where(active: true).order(:id))
    end

    expect(statements.size).to eq(1)
    expect(results.map(&:email)).to eq(["user@example.com"])
  end

  it "uses the records of a relation that is already loaded, in its order" do
    relation = User.order(email: :desc).load
    results = nil
    statements = SqlCounter.capture { results = UserSummary.for(relation) }

    expect(statements.size).to eq(1)
    expect(results.map(&:email)).to eq(%w[user@example.com other@example.com])
  end

  it "reads a paginated relation as its own page, in its own order" do
    results = nil
    statements = SqlCounter.capture { results = UserSummary.for(User.order(:email).limit(1)) }

    expect(statements.size).to eq(2)
    expect(results.map(&:email)).to eq(["other@example.com"])
    expect(UserSummary.for(User.order(:email).offset(1)).map(&:email)).to eq(["user@example.com"])
  end

  it "keeps the joins a paginated relation orders by" do
    Subscription.create!(user_id: user.id, name: "zzz")
    Subscription.create!(user_id: other.id, name: "aaa")

    page = User.eager_load(:subscription).order("subscriptions.name").limit(2)

    expect(UserSummary.for(page).map(&:email)).to eq(%w[other@example.com user@example.com])
  end

  it "applies the conditions of the query to a paginated relation, like an unpaginated one" do
    # The relation says which rows to consider; the query still says which of
    # them it answers for - it does not raise for the ones it filters out.
    expect(UserSummary.where(active: true).for(User.all).map(&:email))
      .to eq(["user@example.com"])
    expect(UserSummary.where(active: true).for(User.order(:id).limit(2)).map(&:email))
      .to eq(["user@example.com"])
  end

  it "still raises for a record it was handed that no longer exists" do
    ghost = User.new
    ghost.id = user.id
    user.destroy!

    expect { UserSummary.for([ghost]) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  # A paginated `.for` is the one read that takes two statements, so it is also
  # the one that could send them to two different databases - a replica for the
  # keys and the primary for the read, say, inside `connected_to`.
  describe "the two statements of a paginated relation" do
    def connections_used
      used = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        payload = ActiveSupport::Notifications::Event.new(*args).payload
        next if %w[SCHEMA TRANSACTION].include?(payload[:name].to_s)

        used << payload[:connection]
      end
      yield
      used
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "run on one and the same connection" do
      used = connections_used { UserSummary.for(User.order(:id).limit(2)) }

      expect(used.size).to eq(2)
      expect(used.uniq.size).to eq(1)
      expect(used.first).to be(User.connection)
    end

    it "both resolve it through the source model, at the moment they run" do
      # Nothing is captured at compile time, so whatever `connected_to` swaps
      # `User.connection` to, both hops follow it together.
      sentinel = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
      allow(User).to receive(:connection).and_return(sentinel)

      expect(UserSummary.compiler.connection).to be(sentinel)
    end

    it "keeps sharing it when the relation is a subclass of the source model" do
      Report.create!(user_id: user.id, title: "one")
      Report.create!(user_id: other.id, title: "two")

      define_query("DocumentSummary") do
        source Document

        schema { field :id }
      end

      used = connections_used { DocumentSummary.for(Report.order(:id).limit(2)) }

      expect(used.uniq.size).to eq(1)
    end
  end

  it "does not instantiate the rows of a paginated relation" do
    expect(User).not_to receive(:instantiate)

    UserSummary.for(User.order(:email).limit(1))
  end

  it "reads a relation with an offset of zero, which pages nothing" do
    expect(UserSummary.for(User.offset(0)).size).to eq(2)
  end

  it "refuses to subquery a grouped relation, which is not valid SQL" do
    expect { UserSummary.for(User.group(:active)) }
      .to raise_error(Pluckr::ConfigurationError, %r{group/having})
  end

  it "does not carry a row lock into a read model" do
    results = nil
    statements = SqlCounter.capture { results = UserSummary.for(User.lock) }

    expect(results.size).to eq(2)
    expect(statements).to all(satisfy { |sql| !sql.match?(/FOR UPDATE/i) })
  end

  # Every way a page can be built has to come back as the page ActiveRecord
  # would have handed over - a `LIMIT` on an eager-loaded collection counts
  # parent rows, not joined ones, and reading the keys the wrong way cuts the
  # page mid fan-out (duplicates, and more rows than were asked for).
  it "pages every shape of relation the way ActiveRecord pages it" do
    [user, other].each do |owner|
      2.times { |i| Photo.create!(user_id: owner.id, url: "#{owner.id}-#{i}") }
      Subscription.create!(user_id: owner.id, name: "sub-#{owner.email}")
    end

    {
      "includes a collection" => User.includes(:photos).order(:id).limit(2),
      "eager_loads a collection" => User.eager_load(:photos).order(:id).limit(2),
      "preloads a collection" => User.preload(:photos).order(:id).limit(2),
      "eager_loads and orders by it" => User.eager_load(:subscription).order("subscriptions.name").limit(1),
      "includes, references and orders by it" =>
        User.includes(:subscription).references(:subscription).order("subscriptions.name").limit(1),
      "joins, fanning out" => User.joins(:photos).order(:id).limit(2),
      "pages plainly" => User.order(:id).limit(2),
      "offsets" => User.order(:id).offset(1),
      "is distinct" => User.distinct.order(:id).limit(2)
    }.each do |shape, page|
      expect(UserSummary.for(page).map(&:id)).to eq(page.to_a.map(&:id)), "#{shape}: page differs"
    end
  end

  it "leaves the rows of a page uninstantiated unless it eager-loads" do
    Photo.create!(user_id: user.id, url: "one")

    expect(User).not_to receive(:instantiate)
    UserSummary.for(User.order(:id).limit(2))
    UserSummary.for(User.preload(:photos).order(:id).limit(2))
  end

  it "gives a paginated relation the row identity its joins give ActiveRecord" do
    Video.create!(user_id: user.id, size: 1)
    Video.create!(user_id: user.id, size: 2)
    page = User.joins(:videos).order("videos.size").limit(3)

    # The relation is the page, duplicates and all - the same rows (and the same
    # repeats) `page.to_a` would have handed over.
    expect(UserSummary.for(page).map(&:id)).to eq(page.pluck(:id))
    expect(UserSummary.for(page).map(&:id)).to eq(UserSummary.for(page.to_a).map(&:id))
  end

  it "rejects another Pluckr query, which holds results and not records" do
    expect { UserSummary.for(UserSummary.where(active: true)) }
      .to raise_error(Pluckr::ConfigurationError, /not another Pluckr query/)
  end

  it "reads any collection of records, not only arrays" do
    expect(UserSummary.for(Set[user]).map(&:email)).to eq(["user@example.com"])
  end

  it "applies the conditions of the query itself" do
    expect { UserSummary.where(active: true).for(other) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "uses a field alias of the primary key to align bulk results" do
    define_query("UserEmail") do
      source User

      schema do
        field :id, as: :user_id
        field :email
      end
    end

    expect(UserEmail.for([other, user]).map(&:user_id)).to eq([other.id, user.id])
  end

  it "needs the primary key on the schema to align several records" do
    define_query("UserEmail") do
      source User

      schema { field :email }
    end

    expect { UserEmail.for([user]) }
      .to raise_error(Pluckr::ConfigurationError, /needs `field :id`/)
  end

  it "rejects records of the wrong model" do
    expect { UserSummary.for(Plan.create!(name: "Pro")) }
      .to raise_error(Pluckr::ConfigurationError, /expects User records, got Plan/)
  end

  it "rejects a relation of the wrong model" do
    expect { UserSummary.for(Plan.all) }
      .to raise_error(Pluckr::ConfigurationError, /expects a relation for User, got Plan/)
  end

  it "rejects a non-record" do
    expect { UserSummary.for(1) }
      .to raise_error(Pluckr::ConfigurationError, /expects User records, got 1/)
  end

  it "needs a source" do
    define_query("Dashboard") do
      schema { count :users, from: User }
    end

    expect { Dashboard.for(user) }.to raise_error(Pluckr::MissingSource)
  end

  it "refuses a composite primary key" do
    Membership.create!(user_id: user.id, plan_id: Plan.create!(name: "Pro").id, role: "owner")

    define_query("MembershipSummary") do
      source Membership

      schema { field :role }
    end

    expect { MembershipSummary.for(Membership.first) }
      .to raise_error(Pluckr::ConfigurationError, /composite primary key/)
  end
end
