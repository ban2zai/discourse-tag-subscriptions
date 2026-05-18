# frozen_string_literal: true

# name: discourse-tag-subscriptions
# about: UI управления подписками на теги в настройках пользователя
# version: 1.0.0
# authors: ban2zai
# enabled_site_setting: tag_subscriptions_enabled

require_relative "lib/tag_subscriptions"
require_relative "lib/tag_subscriptions/post_alerter_extension"

after_initialize do
  reloadable_patch do
    PostAlerter.prepend ::TagSubscriptions::PostAlerterExtension
  end

  class ::TagSubscriptionsController < ::ApplicationController
    requires_login

    def preferences
      target_user = find_target_user
      ensure_can_manage_preferences!(target_user)

      categories = ::TagSubscriptions.visible_categories_for(target_user)
      category_ids = categories.map(&:id)

      render json: {
        categories:
          categories.map do |category|
            {
              id: category.id,
              name: category.name,
              slug: category.slug,
              color: category.color,
              text_color: category.text_color,
            }
          end,
        enabled_category_ids: ::TagSubscriptions.opted_in_category_ids_for(target_user, category_ids),
      }
    end

    def update_preferences
      target_user = find_target_user
      ensure_can_manage_preferences!(target_user)

      visible_category_ids = ::TagSubscriptions.visible_categories_for(target_user).map(&:id)
      enabled_category_ids = parse_category_ids(params[:enabled_category_ids])

      ::TagSubscriptions.replace_visible_opt_ins!(
        user: target_user,
        visible_category_ids: visible_category_ids,
        enabled_category_ids: enabled_category_ids,
      )

      render json: success_json
    end

    def tag_groups
      groups = if current_user.staff?
        TagGroup.includes(:tags, :tag_group_permissions).to_a
      else
        user_group_ids = current_user.group_ids.to_set << 0 # 0 = everyone
        TagGroup.includes(:tags, :tag_group_permissions).select do |tg|
          perm_ids = tg.tag_group_permissions.map(&:group_id)
          perm_ids.empty? || perm_ids.any? { |id| user_group_ids.include?(id) }
        end
      end

      parent_tag_ids = groups.filter_map(&:parent_tag_id)
      parent_tags    = parent_tag_ids.empty? ? {} : Tag.where(id: parent_tag_ids).index_by(&:id)

      render json: {
        tag_groups: groups.map do |tg|
          parent = parent_tags[tg.parent_tag_id]
          {
            id:         tg.id,
            name:       tg.name,
            tags:       tg.tags.map { |t| { id: t.id, name: t.name } },
            parent_tag: parent ? [{ id: parent.id, name: parent.name }] : [],
          }
        end,
      }
    end

    private

    def find_target_user
      username = params[:username].presence
      return current_user if username.blank?

      User.find_by(username_lower: username.downcase) || raise(Discourse::NotFound)
    end

    def ensure_can_manage_preferences!(target_user)
      raise Discourse::InvalidAccess if target_user.id != current_user.id && !current_user.staff?
    end

    def parse_category_ids(value)
      value.to_s.split(",").filter_map do |id|
        id = id.to_i
        id if id.positive?
      end
    end
  end

  Discourse::Application.routes.append do
    get "/tag-subscriptions/tag-groups" => "tag_subscriptions#tag_groups", format: :json
    get "/tag-subscriptions/preferences" => "tag_subscriptions#preferences", format: :json
    put "/tag-subscriptions/preferences" => "tag_subscriptions#update_preferences", format: :json
  end
end
