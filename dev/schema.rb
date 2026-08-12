# frozen_string_literal: true

# The sandbox schema. Indexed the way a real application should be: every
# foreign key used by `exists`/`count` is covered.
ActiveRecord::Schema.verbose = false

ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.boolean :active, null: false, default: true
    t.bigint :manager_id
    t.timestamps
  end
  add_index :users, :email, unique: true
  add_index :users, %i[active id]
  add_index :users, :manager_id
  add_index :users, :created_at

  create_table :plans, force: true do |t|
    t.string :name
    t.integer :price_cents
  end

  create_table :subscriptions, force: true do |t|
    t.references :user, index: { unique: true } # has_one
    t.references :plan
    t.string :name
    t.datetime :cancelled_at
  end

  create_table :photos, force: true do |t|
    t.references :user
    t.string :url
    t.timestamps
  end

  create_table :videos, force: true do |t|
    t.references :user
    t.string :title
    t.integer :size
  end
  add_index :videos, %i[user_id size]

  create_table :comments, force: true do |t|
    t.references :user
    t.text :body
    t.timestamps
  end

  create_table :accounts, force: true do |t|
    t.string :name
    t.boolean :active, null: false, default: false
  end
  add_index :accounts, :active

  create_table :orders, force: true do |t|
    t.references :user
    t.string :status
    t.integer :amount
    t.timestamps
  end
  add_index :orders, %i[status amount]
end
