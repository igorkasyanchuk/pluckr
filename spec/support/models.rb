# frozen_string_literal: true

class User < ActiveRecord::Base
  belongs_to :manager, class_name: "User", optional: true
  belongs_to :region, foreign_key: :region_code, primary_key: :code, optional: true
  has_one :subscription
  has_one :profile, foreign_key: :owner_id, inverse_of: :owner
  has_many :photos
  has_many :videos
  has_many :comments
  has_many :reports
  has_many :documents
  has_many :invoices
  has_many :direct_reports, class_name: "User", foreign_key: :manager_id
  has_many :archived_comments, class_name: "ArchivedComment", foreign_key: :user_id
end

class Region < ActiveRecord::Base
  self.primary_key = "code"

  has_many :users, foreign_key: :region_code, primary_key: :code
end

# Custom table name.
class Invoice < ActiveRecord::Base
  self.table_name = "legacy_invoices"

  belongs_to :user
end

# Single table inheritance: `reports` are documents of type Report.
class Document < ActiveRecord::Base
  belongs_to :user
end

class Report < Document
end

class ArchivedComment < ActiveRecord::Base
  self.table_name = "comments"

  default_scope { where(body: nil) }
end

class Subscription < ActiveRecord::Base
  belongs_to :user
  belongs_to :plan, optional: true
end

class Vendor < ActiveRecord::Base
  has_many :plans
end

class Plan < ActiveRecord::Base
  belongs_to :vendor, optional: true
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
