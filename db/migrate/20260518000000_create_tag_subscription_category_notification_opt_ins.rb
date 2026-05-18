# frozen_string_literal: true

class CreateTagSubscriptionCategoryNotificationOptIns < ActiveRecord::Migration[8.0]
  def change
    create_table :tag_subscription_category_notification_opt_ins do |t|
      t.integer :user_id, null: false
      t.integer :category_id, null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps null: false
    end

    add_index :tag_subscription_category_notification_opt_ins,
              %i[user_id category_id],
              unique: true,
              name: "idx_tag_subscription_category_opt_ins_unique"
    add_index :tag_subscription_category_notification_opt_ins, :category_id
  end
end
