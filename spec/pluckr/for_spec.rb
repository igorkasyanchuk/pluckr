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

  it "refuses to subquery a paginated relation, whose rows would be arbitrary" do
    expect { UserSummary.for(User.order(:email).limit(1)) }
      .to raise_error(Pluckr::ConfigurationError, /limit\/offset/)
    expect { UserSummary.for(User.order(:email).offset(1)) }
      .to raise_error(Pluckr::ConfigurationError, /for\(relation\.to_a\)/)
  end

  it "reads a relation with an offset of zero, which pages nothing" do
    expect(UserSummary.for(User.offset(0)).size).to eq(2)
  end

  it "refuses to subquery a grouped relation, which is not valid SQL" do
    expect { UserSummary.for(User.group(:active)) }
      .to raise_error(Pluckr::ConfigurationError, %r{group/having})
  end

  it "does not carry a row lock into a read model" do
    expect(UserSummary.for(User.lock).size).to eq(2)
    expect(UserSummary.where(id: User.lock.except(*Pluckr::Relation::UNUSED_RELATION_VALUES).select(:id)).to_sql)
      .not_to include("FOR UPDATE")
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
