# frozen_string_literal: true

RSpec.describe "fetch.pluckr instrumentation" do
  let!(:user) { User.create!(email: "user@example.com", active: true) }

  before do
    define_query("UserSummary") do
      source User

      schema do
        field :id
        field :email
      end
    end

    define_query("Dashboard") do
      schema { count :users, from: User }
    end
  end

  def events
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("fetch.pluckr") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    yield
    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "publishes one event per statement, with the query, the SQL and the row count" do
    captured = events { UserSummary.fetch }

    expect(captured.size).to eq(1)
    expect(captured.first.payload[:name]).to eq("UserSummary")
    expect(captured.first.payload[:sql]).to include("SELECT")
    expect(captured.first.payload[:rows]).to eq(1)
    expect(captured.first.duration).to be >= 0
  end

  it "covers find, first and for as well" do
    captured = events do
      UserSummary.find(user.id)
      UserSummary.first
      UserSummary.for(user)
    end

    expect(captured.map { |event| event.payload[:rows] }).to eq([1, 1, 1])
  end

  it "covers aggregate-only queries" do
    captured = events { Dashboard.fetch }

    expect(captured.first.payload[:name]).to eq("Dashboard")
    expect(captured.first.payload[:rows]).to eq(1)
  end

  it "covers Pluckr.batch" do
    captured = events { Pluckr.batch { |batch| batch.count User.all, as: :users } }

    expect(captured.first.payload[:name]).to eq("Pluckr::Batch")
  end

  it "does not fire for the questions ActiveRecord answers itself" do
    expect(events { UserSummary.count }).to be_empty
    expect(events { UserSummary.exists? }).to be_empty
  end

  it "carries the SQL that was actually executed" do
    relation = UserSummary.where(active: true)
    captured = events { relation.fetch }

    expect(captured.first.payload[:sql]).to eq(relation.to_sql)
  end

  it "reports zero rows rather than staying silent" do
    captured = events { UserSummary.where(email: "nobody@example.com").fetch }

    expect(captured.size).to eq(1)
    expect(captured.first.payload[:rows]).to eq(0)
  end

  it "counts the rows of a bulk read, not the calls" do
    others = Array.new(3) { |i| User.create!(email: "bulk#{i}@example.com") }
    captured = events { UserSummary.for(others) }

    expect(captured.size).to eq(1)
    expect(captured.first.payload[:rows]).to eq(3)
  end

  it "fires once per page of a batched read" do
    Array.new(3) { |i| User.create!(email: "page#{i}@example.com") }
    captured = events { UserSummary.find_each(batch_size: 2) { |_| nil } }

    # 4 rows divide evenly, so a third page is read to learn there are no more.
    expect(captured.map { |event| event.payload[:rows] }).to eq([2, 2, 0])
  end

  it "names the subclass that ran, not the query it inherits from" do
    define_query("ActiveUsers") do
      source User
      schema { field :id }
    end
    stub_const("VeryActiveUsers", Class.new(ActiveUsers))

    captured = events { VeryActiveUsers.fetch }

    expect(captured.first.payload[:name]).to eq("VeryActiveUsers")
  end

  it "does not swallow a failing statement" do
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("fetch.pluckr") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end

    expect { UserSummary.where("no_such_column = 1").fetch }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect(captured.first.payload[:rows]).to be_nil
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "leaves the statement in ActiveRecord's own log too, under the query's name" do
    names = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      names << ActiveSupport::Notifications::Event.new(*args).payload[:name]
    end
    UserSummary.fetch
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(names).to include("UserSummary Pluckr")
  end
end
