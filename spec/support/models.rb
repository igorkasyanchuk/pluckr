# frozen_string_literal: true

class User < ActiveRecord::Base
  has_one :subscription
  has_one :profile, foreign_key: :owner_id, inverse_of: :owner
  has_many :photos
  has_many :videos
  has_many :comments
end

class Subscription < ActiveRecord::Base
  belongs_to :user
  belongs_to :plan, optional: true
end

class Plan < ActiveRecord::Base
  has_many :subscriptions
end

class Profile < ActiveRecord::Base
  belongs_to :owner, class_name: "User", foreign_key: :owner_id, inverse_of: :profile
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
end

class Order < ActiveRecord::Base
end
