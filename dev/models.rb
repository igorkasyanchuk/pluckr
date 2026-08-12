# frozen_string_literal: true

class User < ActiveRecord::Base
  belongs_to :manager, class_name: "User", optional: true
  has_one :subscription
  has_many :photos
  has_many :videos
  has_many :comments
  has_many :orders
  has_many :direct_reports, class_name: "User", foreign_key: :manager_id
end

class Plan < ActiveRecord::Base
  has_many :subscriptions
end

class Subscription < ActiveRecord::Base
  belongs_to :user
  belongs_to :plan, optional: true
end

class Photo < ActiveRecord::Base
  belongs_to :user
end

class Video < ActiveRecord::Base
  belongs_to :user
end

class Comment < ActiveRecord::Base
  belongs_to :user
end

class Account < ActiveRecord::Base
  scope :active, -> { where(active: true) }
end

class Order < ActiveRecord::Base
  belongs_to :user, optional: true
end
