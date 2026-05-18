# frozen_string_literal: true

module ::TagSubscriptions
  PLUGIN_NAME = "discourse-tag-subscriptions"

  def self.category_ids_from_setting(value)
    value.to_s.split("|").filter_map do |id|
      id = id.to_i
      id if id.positive?
    end
  end

  def self.gated_category_ids
    category_ids_from_setting(SiteSetting.tag_subscription_gated_categories)
  end

  def self.user_visible_category_ids
    gated_category_ids & category_ids_from_setting(SiteSetting.tag_subscription_user_visible_categories)
  end

  def self.gated_category?(category_id)
    SiteSetting.tag_subscriptions_enabled && gated_category_ids.include?(category_id.to_i)
  end

  def self.visible_categories_for(user)
    guardian = Guardian.new(user)

    Category
      .where(id: user_visible_category_ids)
      .order(:position, :id)
      .select { |category| guardian.can_see_category?(category) }
  end

  def self.opted_in_category_ids_for(user, category_ids)
    return [] if user.blank? || category_ids.blank?

    CategoryNotificationOptIn
      .where(user_id: user.id, category_id: category_ids)
      .pluck(:category_id)
  end

  def self.opted_in_user_ids_for(category_id, user_ids)
    return [] if category_id.blank? || user_ids.blank?

    CategoryNotificationOptIn
      .where(category_id: category_id, user_id: user_ids)
      .pluck(:user_id)
  end

  def self.replace_visible_opt_ins!(user:, visible_category_ids:, enabled_category_ids:)
    visible_category_ids = visible_category_ids.map(&:to_i)
    enabled_category_ids = enabled_category_ids.map(&:to_i) & visible_category_ids

    CategoryNotificationOptIn.transaction do
      CategoryNotificationOptIn
        .where(user_id: user.id, category_id: visible_category_ids)
        .where.not(category_id: enabled_category_ids)
        .delete_all

      existing_ids =
        CategoryNotificationOptIn
          .where(user_id: user.id, category_id: enabled_category_ids)
          .pluck(:category_id)

      now = Time.zone.now
      rows =
        (enabled_category_ids - existing_ids).map do |category_id|
          {
            user_id: user.id,
            category_id: category_id,
            created_at: now,
            updated_at: now,
          }
        end

      CategoryNotificationOptIn.insert_all(rows) if rows.present?
    end
  end
end

class ::TagSubscriptions::CategoryNotificationOptIn < ::ActiveRecord::Base
  self.table_name = "tag_subscription_category_notification_opt_ins"

  belongs_to :user
  belongs_to :category
end
