# frozen_string_literal: true

module ::TagSubscriptions::PostAlerterExtension
  def tag_watchers(topic)
    user_ids = super
    return user_ids if !::TagSubscriptions.gated_category?(topic&.category_id)

    ::TagSubscriptions.tag_notifications_enabled_user_ids_for(topic.category_id, user_ids)
  end

  def notify_post_users(
    post,
    notified,
    group_ids: nil,
    include_topic_watchers: true,
    include_category_watchers: true,
    include_tag_watchers: true,
    new_record: false,
    notification_type: nil
  )
    topic = post.topic
    if !include_tag_watchers || !::TagSubscriptions.gated_category?(topic&.category_id)
      return super
    end

    received_notifications =
      super(
        post,
        notified,
        group_ids: group_ids,
        include_topic_watchers: include_topic_watchers,
        include_category_watchers: include_category_watchers,
        include_tag_watchers: false,
        new_record: new_record,
        notification_type: notification_type,
      )

    received_notifications +
      notify_opted_in_tag_watchers(
        post,
        notified + received_notifications,
        group_ids: group_ids,
        new_record: new_record,
        notification_type: notification_type,
      )
  end

  private

  def notify_opted_in_tag_watchers(post, notified, group_ids:, new_record:, notification_type:)
    topic = post.topic
    tag_ids = topic.topic_tags.pluck("topic_tags.tag_id")
    return [] if tag_ids.blank?

    notify =
      User.where(
        <<~SQL,
          users.id IN (
            SELECT tag_users.user_id
              FROM tag_users
         LEFT JOIN tag_subscription_category_notification_opt_ins tscnoi
                ON tscnoi.user_id = tag_users.user_id
               AND tscnoi.category_id = :category_id
         LEFT JOIN topic_users tu ON tu.user_id = tag_users.user_id
                                 AND tu.topic_id = :topic_id
         LEFT JOIN tag_group_memberships tgm ON tag_users.tag_id = tgm.tag_id
         LEFT JOIN tag_group_permissions tgp ON tgm.tag_group_id = tgp.tag_group_id
         LEFT JOIN group_users gu ON gu.user_id = tag_users.user_id
             WHERE (
                tgp.group_id IS NULL OR
                tgp.group_id = gu.group_id OR
                tgp.group_id = :everyone_group_id OR
                gu.group_id = :staff_group_id
              )
               AND tag_users.notification_level = :watching
               AND tag_users.tag_id IN (:tag_ids)
               AND (tu.user_id IS NULL OR tu.notification_level = :watching)
               AND (
                 tscnoi.enabled IS TRUE OR
                 (tscnoi.id IS NULL AND :default_enabled IS TRUE)
               )
          )
        SQL
        watching: TopicUser.notification_levels[:watching],
        topic_id: post.topic_id,
        category_id: topic.category_id,
        tag_ids: tag_ids,
        default_enabled: ::TagSubscriptions.default_enabled_category_ids.include?(topic.category_id),
        staff_group_id: Group::AUTO_GROUPS[:staff],
        everyone_group_id: Group::AUTO_GROUPS[:everyone],
      )

    if group_ids.present?
      notify = notify.joins(:group_users).where("group_users.group_id IN (?)", group_ids)
    end

    notify = notify.where(staged: false).staff if topic.private_message?

    exclude_user_ids = notified.map(&:id)
    notify = notify.where.not(id: exclude_user_ids) if exclude_user_ids.present?

    DiscourseEvent.trigger(:before_create_notifications_for_users, notify, post)

    already_seen_user_ids =
      Set.new(
        TopicUser
          .where(topic_id: topic.id)
          .where("last_read_post_number >= ?", post.post_number)
          .pluck(:user_id),
      )

    received_notifications = []
    each_user_in_batches(notify) do |user|
      calculated_type =
        if !new_record && already_seen_user_ids.include?(user.id)
          Notification.types[:edited]
        elsif notification_type
          Notification.types[notification_type]
        else
          Notification.types[:posted]
        end

      opts = {}
      opts[:display_username] = post.last_editor.username if calculated_type ==
        Notification.types[:edited]

      received_notifications << user if create_notification(user, calculated_type, post, opts).present?
    end

    received_notifications
  end
end
