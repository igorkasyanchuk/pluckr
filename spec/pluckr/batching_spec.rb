# frozen_string_literal: true

RSpec.describe "find_each / in_batches" do
  let!(:users) { Array.new(5) { |i| User.create!(email: "user#{i}@example.com", active: i.even?) } }

  before do
    define_query("UserSummary") do
      source User

      schema do
        field :id
        field :email
      end
    end
  end

  it "reads every row, in primary key order, a page at a time" do
    seen = []
    statements = SqlCounter.capture { UserSummary.find_each(batch_size: 2) { |row| seen << row.id } }

    expect(seen).to eq(users.map(&:id))
    expect(statements.size).to eq(3) # 2 + 2 + 1, and the short page ends it
  end

  it "yields pages, not rows, from in_batches" do
    pages = []
    UserSummary.in_batches(of: 2) { |page| pages << page.map(&:id) }

    expect(pages).to eq(users.map(&:id).each_slice(2).to_a)
  end

  it "seeks by primary key instead of paging with OFFSET" do
    statements = SqlCounter.capture { UserSummary.find_each(batch_size: 2) { |_| nil } }

    expect(statements.drop(1)).to all(match(/>/))
    expect(statements).to all(satisfy { |sql| !sql.match?(/OFFSET/i) })
  end

  it "applies the conditions of the chain" do
    seen = []
    UserSummary.where(active: true).find_each(batch_size: 2) { |row| seen << row.email }

    expect(seen).to eq(%w[user0@example.com user2@example.com user4@example.com])
  end

  it "ignores an order of its own, like ActiveRecord does" do
    seen = []
    UserSummary.order(email: :desc).find_each(batch_size: 2) { |row| seen << row.id }

    expect(seen).to eq(users.map(&:id))
  end

  it "returns an enumerator without a block" do
    expect(UserSummary.find_each(batch_size: 2).map(&:id)).to eq(users.map(&:id))
    expect(UserSummary.in_batches(of: 2).to_a.size).to eq(3)
  end

  it "does nothing when nothing matches" do
    expect { |block| UserSummary.where(email: "nobody@example.com").find_each(&block) }
      .not_to yield_control
  end

  it "refuses a chain that already pages, which it would silently override" do
    expect { UserSummary.limit(2).find_each { |_| nil } }
      .to raise_error(Pluckr::ConfigurationError, %r{`limit`/`offset`})
    expect { UserSummary.offset(2).in_batches { |_| nil } }
      .to raise_error(Pluckr::ConfigurationError, /find_each/)
  end

  it "refuses a page size that would read nothing, or everything" do
    expect { UserSummary.find_each(batch_size: 0) { |_| nil } }
      .to raise_error(ArgumentError, /positive integer/)
    expect { UserSummary.in_batches(of: 0) { |_| nil } }
      .to raise_error(ArgumentError, /positive integer/)
    expect { UserSummary.in_batches(of: nil) { |_| nil } }
      .to raise_error(ArgumentError, /positive integer/)
    expect { UserSummary.find_each(batch_size: -1) { |_| nil } }
      .to raise_error(ArgumentError, /positive integer/)
    expect { UserSummary.find_each(batch_size: 2.5) { |_| nil } }
      .to raise_error(ArgumentError, /positive integer/)
  end

  it "refuses that page size before the enumerator defers the work" do
    expect { UserSummary.find_each(batch_size: 0) }.to raise_error(ArgumentError)
    expect { UserSummary.in_batches(of: nil) }.to raise_error(ArgumentError)
  end

  it "refuses it up front, before an enumerator defers the work" do
    expect { UserSummary.limit(2).find_each }
      .to raise_error(Pluckr::ConfigurationError, %r{`limit`/`offset`})
    expect { UserSummary.offset(2).in_batches }
      .to raise_error(Pluckr::ConfigurationError, %r{`limit`/`offset`})
  end

  it "names the paging problem even when the schema also lacks a primary key" do
    define_query("UserEmail") do
      source User

      schema { field :email }
    end

    expect { UserEmail.limit(2).find_each { |_| nil } }
      .to raise_error(Pluckr::ConfigurationError, %r{`limit`/`offset`})
  end

  it "needs the primary key on the schema to seek" do
    define_query("UserEmail") do
      source User

      schema { field :email }
    end

    expect { UserEmail.find_each { |_| nil } }
      .to raise_error(Pluckr::ConfigurationError, /UserEmail needs `field :id`/)
  end

  it "says so without blaming `.for`, which the caller never used" do
    define_query("UserEmail") do
      source User

      schema { field :email }
    end

    expect { UserEmail.find_each { |_| nil } }
      .to raise_error(Pluckr::ConfigurationError) { |error| expect(error.message).not_to include(".for") }
  end

  it "spends one extra statement when the rows divide evenly into pages" do
    users.last.destroy! # 4 rows, pages of 2

    pages = nil
    statements = SqlCounter.capture { pages = UserSummary.in_batches(of: 2).to_a }

    expect(pages.map(&:size)).to eq([2, 2])
    expect(statements.size).to eq(3) # the third comes back empty and ends it
  end

  it "reads one page per batch, whatever the schema costs" do
    define_query("UserCard") do
      source User

      schema do
        field :id
        one :subscription do
          field :name
        end
        count :videos
        exists :photos
      end
    end

    statements = SqlCounter.capture { UserCard.find_each(batch_size: 2) { |_| nil } }

    expect(statements.size).to eq(3)
  end

  it "stops early when the caller does" do
    statements = SqlCounter.capture { UserSummary.find_each(batch_size: 2).first }

    expect(statements.size).to eq(1)
  end

  it "yields the frozen result objects `fetch` returns" do
    row = UserSummary.find_each(batch_size: 2).first

    expect(row).to be_a(Pluckr::Result::Object)
    expect(row).to be_frozen
    expect(row.email).to eq(users.first.email)
  end

  it "reads one row at a time when told to" do
    seen = []
    statements = SqlCounter.capture { UserSummary.find_each(batch_size: 1) { |row| seen << row.id } }

    expect(seen).to eq(users.map(&:id))
    expect(statements.size).to eq(6) # 5 rows, then the empty page
  end

  it "seeks over a string primary key" do
    %w[cz pl ua].each { |code| Region.create!(code: code, title: code.upcase) }

    define_query("RegionSummary") do
      source Region

      schema do
        field :code
        field :title
      end
    end

    seen = []
    RegionSummary.find_each(batch_size: 2) { |row| seen << row.code }

    expect(seen).to eq(%w[cz pl ua])
  end

  it "refuses a composite primary key, which it cannot seek over" do
    plan = Plan.create!(name: "Pro")
    Membership.create!(user_id: users.first.id, plan_id: plan.id, role: "owner")

    define_query("MembershipSummary") do
      source Membership

      schema { field :role }
    end

    expect { MembershipSummary.find_each { |_| nil } }
      .to raise_error(Pluckr::ConfigurationError, /composite primary key/)
  end

  it "uses a field alias of the primary key" do
    define_query("UserEmail") do
      source User

      schema do
        field :id, as: :user_id
        field :email
      end
    end

    seen = []
    UserEmail.find_each(batch_size: 2) { |row| seen << row.user_id }

    expect(seen).to eq(users.map(&:id))
  end
end
