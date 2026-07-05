# frozen_string_literal: true

RSpec.describe TagSubscriptionsController do
  fab!(:user) { Fabricate(:user) }
  fab!(:other_user) { Fabricate(:user) }
  fab!(:admin) { Fabricate(:admin) }
  fab!(:category) { Fabricate(:category) }
  fab!(:second_category) { Fabricate(:category) }
  fab!(:subscription_group) { Fabricate(:group, name: "tz-access") }

  before do
    SiteSetting.tag_subscription_gated_categories = category.id.to_s
  end

  it "returns visible category preferences for the current user" do
    sign_in(user)
    TagSubscriptions::CategoryNotificationOptIn.create!(user: user, category: category)

    get "/tag-subscriptions/preferences.json", params: { username: user.username }

    expect(response.status).to eq(200)
    json = response.parsed_body
    response_category = json["categories"].first
    expect(json["categories"].map { |c| c["id"] }).to eq([category.id])
    expect(response_category["style_type"]).to eq(category.style_type)
    expect(response_category).to have_key("icon")
    expect(response_category).to have_key("emoji")
    expect(json["enabled_category_ids"]).to eq([category.id])
  end

  it "returns default-enabled category preferences when the user has no override" do
    SiteSetting.tag_subscription_default_enabled_categories = category.id.to_s
    sign_in(user)

    get "/tag-subscriptions/preferences.json", params: { username: user.username }

    expect(response.status).to eq(200)
    expect(response.parsed_body["enabled_category_ids"]).to eq([category.id])
  end

  it "returns group-default category preferences when the user has no override" do
    SiteSetting.tag_subscription_gated_categories = "#{category.id}|#{second_category.id}"
    SiteSetting.tag_subscription_group_default_enabled_categories =
      %Q("tz-access":"#{category.id}"|"other-group":"#{second_category.id}")
    subscription_group.add(user)
    sign_in(user)

    get "/tag-subscriptions/preferences.json", params: { username: user.username }

    expect(response.status).to eq(200)
    expect(response.parsed_body["enabled_category_ids"]).to eq([category.id])
  end

  it "lets user overrides disable group-default category preferences" do
    SiteSetting.tag_subscription_group_default_enabled_categories = %Q("tz-access":"#{category.id}")
    subscription_group.add(user)
    TagSubscriptions::CategoryNotificationOptIn.create!(
      user: user,
      category: category,
      enabled: false,
    )
    sign_in(user)

    get "/tag-subscriptions/preferences.json", params: { username: user.username }

    expect(response.status).to eq(200)
    expect(response.parsed_body["enabled_category_ids"]).to eq([])
  end

  it "returns categories in the gated setting order" do
    SiteSetting.tag_subscription_gated_categories = "#{second_category.id}|#{category.id}"
    sign_in(user)

    get "/tag-subscriptions/preferences.json", params: { username: user.username }

    expect(response.status).to eq(200)
    expect(response.parsed_body["categories"].map { |c| c["id"] }).to eq(
      [second_category.id, category.id],
    )
  end

  it "lets the current user replace visible category opt-ins" do
    sign_in(user)

    put "/tag-subscriptions/preferences.json",
        params: {
          username: user.username,
          enabled_category_ids: category.id.to_s,
        }

    expect(response.status).to eq(200)
    expect(
      TagSubscriptions::CategoryNotificationOptIn.exists?(user: user, category: category),
    ).to eq(true)
  end

  it "stores disabled overrides for default-enabled categories" do
    SiteSetting.tag_subscription_default_enabled_categories = category.id.to_s
    sign_in(user)

    put "/tag-subscriptions/preferences.json",
        params: {
          username: user.username,
          enabled_category_ids: "",
        }

    expect(response.status).to eq(200)
    preference = TagSubscriptions::CategoryNotificationOptIn.find_by(user: user, category: category)
    expect(preference.enabled).to eq(false)
  end

  it "lets staff manage another user's category opt-ins" do
    sign_in(admin)

    put "/tag-subscriptions/preferences.json",
        params: {
          username: user.username,
          enabled_category_ids: category.id.to_s,
        }

    expect(response.status).to eq(200)
    expect(
      TagSubscriptions::CategoryNotificationOptIn.exists?(user: user, category: category),
    ).to eq(true)
  end

  it "does not let a regular user manage another user's category opt-ins" do
    sign_in(user)

    put "/tag-subscriptions/preferences.json",
        params: {
          username: other_user.username,
          enabled_category_ids: category.id.to_s,
        }

    expect(response.status).to eq(403)
    expect(
      TagSubscriptions::CategoryNotificationOptIn.exists?(user: other_user, category: category),
    ).to eq(false)
  end
end
