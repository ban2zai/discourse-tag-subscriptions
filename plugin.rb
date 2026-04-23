# frozen_string_literal: true

# name: discourse-tag-subscriptions
# about: UI управления подписками на теги в настройках пользователя
# version: 1.0.0
# authors: ban2zai

after_initialize do
  class ::TagSubscriptionsController < ::ApplicationController
    requires_login

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
  end

  Discourse::Application.routes.append do
    get "/tag-subscriptions/tag-groups" => "tag_subscriptions#tag_groups", format: :json
  end
end
