# frozen_string_literal: true

RSpec.describe TagSubscriptionsController do
  fab!(:user) { Fabricate(:user) }
  fab!(:other_user) { Fabricate(:user) }
  fab!(:admin) { Fabricate(:admin) }
  fab!(:category) { Fabricate(:category) }

  before do
    SiteSetting.tag_subscription_gated_categories = category.id.to_s
    SiteSetting.tag_subscription_user_visible_categories = category.id.to_s
  end

  it "returns visible category preferences for the current user" do
    sign_in(user)
    TagSubscriptions::CategoryNotificationOptIn.create!(user: user, category: category)

    get "/tag-subscriptions/preferences.json", params: { username: user.username }

    expect(response.status).to eq(200)
    json = response.parsed_body
    expect(json["categories"].map { |c| c["id"] }).to eq([category.id])
    expect(json["enabled_category_ids"]).to eq([category.id])
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
