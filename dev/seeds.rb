# frozen_string_literal: true

module Seeds
  PLANS = [["Free", 0], ["Pro", 2_900], ["Team", 9_900]].freeze
  STATUSES = %w[paid pending refunded].freeze

  module_function

  # Deterministic, so the console shows the same thing every time.
  def run(users: 20)
    random = Random.new(42)
    clear!

    plans = PLANS.map { |name, price| Plan.create!(name: name, price_cents: price) }
    boss = User.create!(email: "boss@example.com", name: "Boss", active: true)

    (1..users).each do |i|
      user = User.create!(
        email: "user#{i}@example.com",
        name: "User #{i}",
        active: i % 4 != 0,
        manager: (boss unless i % 5 == 0),
        created_at: Time.now - (i * 86_400)
      )

      # Most users have a subscription; some have one without a plan.
      if i % 3 != 0
        Subscription.create!(user: user, plan: (plans[i % plans.size] if i % 7 != 0),
                             name: "sub-#{i}")
      end

      random.rand(0..3).times { |n| Photo.create!(user: user, url: "https://example.com/#{i}-#{n}.jpg") }
      random.rand(0..4).times do |n|
        Video.create!(user: user, title: "video #{i}-#{n}", size: random.rand(10..500))
      end
      random.rand(0..5).times { |n| Comment.create!(user: user, body: "comment #{i}-#{n}") }
      random.rand(0..3).times do
        Order.create!(user: user, status: STATUSES.sample(random: random), amount: random.rand(5..500))
      end
    end

    10.times { |i| Account.create!(name: "account-#{i}", active: i.even?) }

    puts "seeded #{Dev.counts.map { |table, count| "#{count} #{table}" }.join(", ")}"
  end

  def clear!
    [Order, Comment, Video, Photo, Subscription, Account, Plan, User].each(&:delete_all)
  end
end
