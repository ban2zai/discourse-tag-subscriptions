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

  def self.default_enabled_category_ids
    gated_category_ids & category_ids_from_setting(SiteSetting.tag_subscription_default_enabled_categories)
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

  def self.enabled_category_ids_for(user, category_ids)
    return [] if user.blank? || category_ids.blank?

    category_ids = category_ids.map(&:to_i)
    default_ids = default_enabled_category_ids & category_ids
    overrides =
      CategoryNotificationOptIn
      .where(user_id: user.id, category_id: category_ids)
      .pluck(:category_id, :enabled)
      .to_h

    category_ids.select do |category_id|
      overrides.key?(category_id) ? overrides[category_id] : default_ids.include?(category_id)
    end
  end

  def self.tag_notifications_enabled_user_ids_for(category_id, user_ids)
    return [] if category_id.blank? || user_ids.blank?

    user_ids = user_ids.map(&:to_i)
    overrides =
      CategoryNotificationOptIn
      .where(category_id: category_id, user_id: user_ids)
      .pluck(:user_id, :enabled)
      .to_h

    default_enabled = default_enabled_category_ids.include?(category_id.to_i)

    user_ids.select do |user_id|
      overrides.key?(user_id) ? overrides[user_id] : default_enabled
    end
  end

  def self.replace_visible_preferences!(user:, visible_category_ids:, enabled_category_ids:)
    visible_category_ids = visible_category_ids.map(&:to_i)
    enabled_category_ids = enabled_category_ids.map(&:to_i) & visible_category_ids

    CategoryNotificationOptIn.transaction do
      existing =
        CategoryNotificationOptIn
          .where(user_id: user.id, category_id: visible_category_ids)
          .index_by(&:category_id)

      now = Time.zone.now
      visible_category_ids.each do |category_id|
        enabled = enabled_category_ids.include?(category_id)
        record = existing[category_id]

        if record
          record.update!(enabled: enabled)
        else
          CategoryNotificationOptIn.create!(
            user_id: user.id,
            category_id: category_id,
            enabled: enabled,
            created_at: now,
            updated_at: now,
          )
        end
      end
    end
  end
end

class ::TagSubscriptions::CategoryNotificationOptIn < ::ActiveRecord::Base
  self.table_name = "tag_subscription_category_notification_opt_ins"

  belongs_to :user
  belongs_to :category
end
