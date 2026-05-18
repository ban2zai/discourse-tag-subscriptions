# frozen_string_literal: true

RSpec.describe "tag subscription category notification opt-ins" do
  fab!(:normal_category) { Fabricate(:category) }
  fab!(:gated_category) { Fabricate(:category) }
  fab!(:tag) { Fabricate(:tag) }
  fab!(:watcher) { Fabricate(:user) }
  fab!(:category_watcher) { Fabricate(:user) }
  fab!(:poster) { Fabricate(:user) }

  before do
    SiteSetting.tag_subscription_gated_categories = gated_category.id.to_s
    SiteSetting.tag_subscription_user_visible_categories = gated_category.id.to_s
  end

  def tagged_topic(category)
    Fabricate(:topic, category: category, tags: [tag])
  end

  def create_post_with_alerts(topic, args = {})
    post = Fabricate(:post, { topic: topic, user: poster }.merge(args))
    PostAlerter.post_created(post)
    post
  end

  def notification_count(user, type)
    user.notifications.where(notification_type: Notification.types[type]).count
  end

  it "keeps watched tag first-post notifications in normal categories" do
    TagUser.change(watcher.id, tag.id, TagUser.notification_levels[:watching_first_post])

    create_post_with_alerts(tagged_topic(normal_category))

    expect(notification_count(watcher, :watching_first_post)).to eq(1)
  end

  it "suppresses watched tag first-post notifications in gated categories without opt-in" do
    TagUser.change(watcher.id, tag.id, TagUser.notification_levels[:watching_first_post])

    create_post_with_alerts(tagged_topic(gated_category))

    expect(notification_count(watcher, :watching_first_post)).to eq(0)
  end

  it "allows watched tag first-post notifications in gated categories with opt-in" do
    TagUser.change(watcher.id, tag.id, TagUser.notification_levels[:watching_first_post])
    TagSubscriptions::CategoryNotificationOptIn.create!(user: watcher, category: gated_category)

    create_post_with_alerts(tagged_topic(gated_category))

    expect(notification_count(watcher, :watching_first_post)).to eq(1)
  end

  it "suppresses watched tag reply notifications in gated categories without opt-in" do
    topic = tagged_topic(gated_category)
    Fabricate(:post, topic: topic)
    TagUser.change(watcher.id, tag.id, TagUser.notification_levels[:watching])

    create_post_with_alerts(topic)

    expect(notification_count(watcher, :watching_category_or_tag)).to eq(0)
  end

  it "allows watched tag reply notifications in gated categories with opt-in" do
    topic = tagged_topic(gated_category)
    Fabricate(:post, topic: topic)
    TagUser.change(watcher.id, tag.id, TagUser.notification_levels[:watching])
    TagSubscriptions::CategoryNotificationOptIn.create!(user: watcher, category: gated_category)

    create_post_with_alerts(topic)

    expect(notification_count(watcher, :watching_category_or_tag)).to eq(1)
  end

  it "keeps watched category notifications in gated categories without opt-in" do
    CategoryUser.set_notification_level_for_category(
      category_watcher,
      CategoryUser.notification_levels[:watching_first_post],
      gated_category.id,
    )

    create_post_with_alerts(tagged_topic(gated_category))

    expect(notification_count(category_watcher, :watching_first_post)).to eq(1)
  end

  it "keeps direct mention notifications in gated categories without opt-in" do
    create_post_with_alerts(tagged_topic(gated_category), raw: "Hello @#{watcher.username}")

    expect(notification_count(watcher, :mentioned)).to eq(1)
  end

  it "keeps direct reply notifications in gated categories without opt-in" do
    topic = tagged_topic(gated_category)
    watched_post = Fabricate(:post, topic: topic, user: watcher)

    create_post_with_alerts(topic, reply_to_post_number: watched_post.post_number)

    expect(notification_count(watcher, :replied)).to eq(1)
  end
end
