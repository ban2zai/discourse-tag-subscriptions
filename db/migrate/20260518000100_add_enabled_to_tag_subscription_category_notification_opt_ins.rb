# frozen_string_literal: true

class AddEnabledToTagSubscriptionCategoryNotificationOptIns < ActiveRecord::Migration[8.0]
  def change
    if !column_exists?(:tag_subscription_category_notification_opt_ins, :enabled)
      add_column :tag_subscription_category_notification_opt_ins,
                 :enabled,
                 :boolean,
                 null: false,
                 default: true
    end
  end
end
