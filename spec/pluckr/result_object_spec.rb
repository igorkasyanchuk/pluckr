# frozen_string_literal: true

RSpec.describe Pluckr::Result::Object do
  let!(:user) { User.create!(email: "user@example.com") }
  let!(:subscription) { Subscription.create!(user: user, name: "Pro") }

  before do
    2.times { Video.create!(user: user) }
    Photo.create!(user: user)

    define_query("UserSummary") do
      source User

      schema do
        field :id
        field :email

        one :subscription do
          field :id
          field :name
        end

        exists :photos
        count :videos
      end
    end
  end

  subject(:result) { UserSummary.find(user.id) }

  it "matches the documented MVP example" do
    expect(result.id).to eq(user.id)
    expect(result.email).to eq("user@example.com")
    expect(result.subscription.id).to eq(subscription.id)
    expect(result.subscription.name).to eq("Pro")
    expect(result.photos_exists).to be(true)
    expect(result.videos_count).to eq(2)
  end

  it "returns a nested to_h without internal aliases" do
    expect(result.to_h).to eq(
      id: user.id,
      email: "user@example.com",
      subscription: { id: subscription.id, name: "Pro" },
      photos_exists: true,
      videos_count: 2
    )
  end

  it "is immutable" do
    expect(result).to be_frozen
    expect { result.instance_variable_set(:@attributes, {}) }.to raise_error(FrozenError)
  end

  it "is not an ActiveRecord object" do
    expect(result).not_to be_a(ActiveRecord::Base)
    expect(result.class.ancestors).not_to include(ActiveRecord::Base)
  end

  it "has a useful inspect" do
    expect(result.inspect).to start_with("#<UserSummary id=")
    expect(result.inspect).to include('email="user@example.com"')
    expect(result.inspect).to include("#<UserSummary.subscription ")
    expect(result.inspect).not_to include("__pluckr")
  end

  it "supports [] access" do
    expect(result[:email]).to eq("user@example.com")
    expect(result["email"]).to eq("user@example.com")
  end

  it "exposes its keys" do
    expect(result.keys).to eq(%i[id email subscription photos_exists videos_count])
  end

  it "compares by value" do
    expect(result).to eq(UserSummary.find(user.id))
  end

  it "raises NoMethodError for anything not selected" do
    expect { result.created_at }.to raise_error(NoMethodError)
  end
end
