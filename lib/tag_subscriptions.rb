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

  def self.default_enabled_category_ids
    gated_category_ids & category_ids_from_setting(SiteSetting.tag_subscription_default_enabled_categories)
  end

  def self.group_default_enabled_category_ids_by_group
    SiteSetting
      .tag_subscription_group_default_enabled_categories
      .to_s
      .split("|")
      .each_with_object({}) do |entry, result|
      match = entry.strip.match(/\A"([^"]+)"\s*:\s*"(\d+)"\z/)
      next if match.blank?

      group_name = match[1].strip
      category_id = match[2].to_i
      next if group_name.blank? || !category_id.positive?

      result[group_name] ||= []
      result[group_name] << category_id
    end
  end

  def self.group_names_defaulting_category(category_id)
    category_id = category_id.to_i

    group_default_enabled_category_ids_by_group.filter_map do |group_name, category_ids|
      group_name if category_ids.include?(category_id)
    end
  end

  def self.default_enabled_category_ids_for(user)
    default_ids = default_enabled_category_ids
    return default_ids if user.blank?

    group_defaults = group_default_enabled_category_ids_by_group
    return default_ids if group_defaults.blank?

    group_names = GroupUser.joins(:group).where(user_id: user.id).pluck("groups.name")
    group_default_ids = group_defaults.values_at(*group_names).flatten.compact

    gated_category_ids & (default_ids + group_default_ids).uniq
  end

  def self.gated_category?(category_id)
    SiteSetting.tag_subscriptions_enabled && gated_category_ids.include?(category_id.to_i)
  end

  def self.visible_categories_for(user)
    guardian = Guardian.new(user)
    category_ids = gated_category_ids
    categories_by_id = Category.where(id: category_ids).index_by(&:id)

    category_ids.filter_map do |category_id|
      category = categories_by_id[category_id]
      category if category && guardian.can_see_category?(category)
    end
  end

  def self.enabled_category_ids_for(user, category_ids)
    return [] if user.blank? || category_ids.blank?

    category_ids = category_ids.map(&:to_i)
    default_ids = default_enabled_category_ids_for(user) & category_ids
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

    category_id = category_id.to_i
    default_enabled_user_ids =
      if default_enabled_category_ids.include?(category_id)
        user_ids.to_set
      else
        group_names = group_names_defaulting_category(category_id)
        if group_names.present?
          GroupUser
            .joins(:group)
            .where(user_id: user_ids, groups: { name: group_names })
            .distinct
            .pluck(:user_id)
            .to_set
        else
          Set.new
        end
      end

    user_ids.select do |user_id|
      overrides.key?(user_id) ? overrides[user_id] : default_enabled_user_ids.include?(user_id)
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
