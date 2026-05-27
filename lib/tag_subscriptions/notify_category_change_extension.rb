# frozen_string_literal: true

module ::TagSubscriptions::NotifyCategoryChangeExtension
  def execute(args)
    super

    post = Post.find_by(id: args[:post_id])
    topic = post&.topic
    return if !topic&.visible?
    return if !::TagSubscriptions.gated_category?(topic.category_id)

    tag_names = topic.tags.pluck(:name)
    return if tag_names.blank?

    Jobs.enqueue(
      :notify_tag_change,
      post_id: post.id,
      notified_user_ids: args[:notified_user_ids] || [],
      diff_tags: tag_names,
      force: true,
    )
  end
end
