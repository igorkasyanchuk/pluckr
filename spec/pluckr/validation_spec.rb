# frozen_string_literal: true

RSpec.describe "schema validation" do
  it "rejects unknown columns" do
    expect do
      define_query("Bad") do
        source User

        schema do
          field :does_not_exist
        end
      end
    end.to raise_error(Pluckr::UnknownField, "User does not have column `does_not_exist`")
  end

  it "rejects unknown associations" do
    expect do
      define_query("Bad") do
        source User

        schema do
          one :unknown do
            field :id
          end
        end
      end
    end.to raise_error(Pluckr::UnknownAssociation, "User does not have association `unknown`")
  end

  it "rejects unknown associations in exists" do
    expect do
      define_query("Bad") do
        source User

        schema do
          exists :unknown
        end
      end
    end.to raise_error(Pluckr::UnknownAssociation)
  end

  it "rejects unknown columns inside a nested one" do
    expect do
      define_query("Bad") do
        source User

        schema do
          one :subscription do
            field :nope
          end
        end
      end
    end.to raise_error(Pluckr::UnknownField, "Subscription does not have column `nope`")
  end

  it "rejects root fields without a source" do
    expect do
      define_query("Bad") do
        schema do
          field :id
        end
      end
    end.to raise_error(Pluckr::MissingSource, /field :id/)
  end

  it "rejects a correlated count without a source" do
    expect do
      define_query("Bad") do
        schema do
          count :videos
        end
      end
    end.to raise_error(Pluckr::MissingSource)
  end

  it "rejects sum without a column" do
    expect do
      define_query("Bad") do
        schema do
          sum :revenue, from: Order
        end
      end
    end.to raise_error(Pluckr::ConfigurationError, "`sum :revenue` requires `column:`")
  end

  it "rejects an unknown aggregate column" do
    expect do
      define_query("Bad") do
        schema do
          sum :revenue, from: Order, column: :nope
        end
      end
    end.to raise_error(Pluckr::UnknownField, "Order does not have column `nope`")
  end

  it "rejects an unknown column in a where condition" do
    expect do
      define_query("Bad") do
        schema do
          count :orders, from: Order, where: { nope: 1 }
        end
      end
    end.to raise_error(Pluckr::UnknownField, "Order does not have column `nope`")
  end

  it "rejects a non-model from:" do
    expect do
      define_query("Bad") do
        schema do
          count :orders, from: :orders
        end
      end
    end.to raise_error(Pluckr::ConfigurationError, /expects an ActiveRecord model/)
  end

  it "rejects a non-model source" do
    expect do
      define_query("Bad") { source :users }
    end.to raise_error(Pluckr::ConfigurationError, /expects an ActiveRecord model/)
  end

  it "rejects duplicate output names" do
    expect do
      define_query("Bad") do
        source User

        schema do
          field :email
          field :id, as: :email
        end
      end
    end.to raise_error(Pluckr::ConfigurationError, "duplicate output name `email` in schema")
  end

  it "rejects one without a block" do
    expect do
      define_query("Bad") do
        source User

        schema { one :subscription }
      end
    end.to raise_error(Pluckr::ConfigurationError, /requires a block/)
  end

  it "raises when a query has no schema" do
    define_query("Bad") { source User }

    expect { Bad.to_sql }.to raise_error(Pluckr::ConfigurationError, /has no `schema` block/)
  end

  it "inherits source and schema from the query it subclasses" do
    user = User.create!(email: "user@example.com")

    define_query("UserSummary") do
      source User

      schema do
        field :id
        field :email
      end
    end
    stub_const("AdminSummary", Class.new(UserSummary))

    expect(AdminSummary.source_model).to eq(User)
    expect(AdminSummary.find(user.id).email).to eq("user@example.com")
    expect(AdminSummary.to_sql).to eq(UserSummary.to_sql)
  end

  it "lets a subclass declare its own schema" do
    user = User.create!(email: "user@example.com")

    define_query("UserSummary") do
      source User

      schema { field :email }
    end
    stub_const("AdminSummary", Class.new(UserSummary) do
      schema do
        field :id
        count :videos
      end
    end)

    expect(AdminSummary.find(user.id).to_h).to eq(id: user.id, videos_count: 0)
    expect(UserSummary.find(user.id).to_h).to eq(email: "user@example.com")
  end

  it "rejects reading two databases in one statement" do
    stub_const("Elsewhere", Class.new(ActiveRecord::Base) { self.table_name = "accounts" })
    allow(Elsewhere).to receive(:connection_pool).and_return(Object.new)

    define_query("Bad") do
      schema do
        count :here, from: User
        count :there, from: Elsewhere
      end
    end

    expect { Bad.to_sql }
      .to raise_error(Pluckr::ConfigurationError, /different database connections/)
  end

  it "rejects associations Pluckr cannot compile yet" do
    stub_const("Taggable", Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      has_many :recent_photos, -> { order(id: :desc) }, class_name: "Photo", foreign_key: :user_id
    end)

    expect do
      define_query("Bad") do
        source Taggable

        schema { exists :recent_photos }
      end
    end.to raise_error(Pluckr::UnsupportedAssociation, /has a scope/)
  end
end
