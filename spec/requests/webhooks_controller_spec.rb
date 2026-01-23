# frozen_string_literal: true

require "rails_helper"

describe BevyPlugin::WebhooksController do
  let(:bevy_event_payload) do
    JSON.parse(File.read(File.join(__dir__, "../fixtures/json/bevy_event_payload.json")))
  end

  before do
    SiteSetting.bevy_plugin_enabled = true
    SiteSetting.calendar_enabled = true
    SiteSetting.discourse_post_event_enabled = true
    Jobs.run_immediately!
  end

  describe "invalid authorization token" do
    before { SiteSetting.bevy_webhook_api_key = "test" }

    it "returns 401 unauthorized when signature doesn't match" do
      post "/bevy/webhooks.json",
           params: bevy_event_payload.to_json,
           headers: {
             "X-BEVY-SECRET": "wrong-token",
             CONTENT_TYPE: "application/json",
           }

      expect(response.status).to eq(401)
      expect(response.parsed_body["error"]).to eq("Unauthorized")
    end

    it "returns 401 unauthorized when signature is missing" do
      post "/bevy/webhooks.json",
           params: bevy_event_payload.to_json,
           headers: {
             CONTENT_TYPE: "application/json",
           }

      expect(response.status).to eq(401)
      expect(response.parsed_body["error"]).to eq("Unauthorized")
    end
  end

  describe "valid authorization token" do
    before { SiteSetting.bevy_webhook_api_key = "test" }
    context "when webhook type is event" do
      it "creates a bevy_event and topic with an event" do
        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)

        bevy_event_topic = Topic.last
        payload_data = bevy_event_payload.first["data"].first
        bevy_event = BevyEvent.last

        expect(bevy_event.bevy_event_id).to eq(payload_data["id"])
        expect(bevy_event.post_id).to eq(Post.last.id)
        expect(bevy_event.bevy_updated_ts).to be_present

        expect(bevy_event_topic.title).to eq(payload_data["title"])
        expect(bevy_event_topic.first_post.raw).to include("Bevy")

        expect(DiscoursePostEvent::EventDate.last.starts_at.strftime("%Y-%m-%d %H:%M")).to eq(
          Time.parse(payload_data["start_date"]).utc.strftime("%Y-%m-%d %H:%M"),
        )
        expect(DiscoursePostEvent::EventDate.last.ends_at.strftime("%Y-%m-%d %H:%M")).to eq(
          Time.parse(payload_data["end_date"]).utc.strftime("%Y-%m-%d %H:%M"),
        )
      end

      it "updates an existing event when webhook is received again" do
        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)

        topic = Topic.last
        bevy_event = BevyEvent.last

        updated_payload = bevy_event_payload.deep_dup
        updated_payload.first["data"].first["title"] = "Updated Event Title"
        updated_payload.first["data"].first["description_short"] = "Updated description"
        updated_payload.first["data"].first["updated_ts"] = "#{Time.now}"

        post "/bevy/webhooks.json",
             params: updated_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)

        # Should update the same topic, not create a new one
        expect(Topic.count).to eq(1)
        expect(BevyEvent.count).to eq(1)

        updated_topic = Topic.find(topic.id)
        expect(updated_topic.title).to eq("Updated Event Title")
        expect(updated_topic.first_post.raw).to include("Updated description")

        # BevyEvent should still point to the same topic
        expect(bevy_event.reload.post.topic.id).to eq(topic.id)
      end

      it "applies tags from JMESPath rules to created topics" do
        SiteSetting.bevy_events_tag_rules =
          "has-venue,venue_name|virtual,event_type_title == 'Virtual Event type'"

        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)

        topic = Topic.last
        tag_names = topic.tags.pluck(:name)

        # venue_name is present in fixture, so "has-venue" should be added
        expect(tag_names).to include("has-venue")

        # Check if virtual tag is added based on event_type_title
        payload_data = bevy_event_payload.first["data"].first
        if payload_data["event_type_title"] == "Virtual Event type"
          expect(tag_names).to include("virtual")
        else
          expect(tag_names).not_to include("virtual")
        end
      end

      it "updates tags when event is updated" do
        SiteSetting.bevy_events_tag_rules = "has-venue,venue_name"

        # Create initial event
        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        topic = Topic.last
        expect(topic.tags.pluck(:name)).to include("has-venue")

        # Update event to remove venue
        updated_payload = bevy_event_payload.deep_dup
        updated_payload.first["data"].first["venue_name"] = nil
        updated_payload.first["data"].first["updated_ts"] = "#{Time.now}"

        post "/bevy/webhooks.json",
             params: updated_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        topic.reload
        # Tag should be removed since venue_name is now nil
        expect(topic.tags.pluck(:name)).not_to include("has-venue")
      end
    end
    context "when webhook type is attendee" do
      fab!(:post_event, :post)
      fab!(:event) { Fabricate(:event, post: post_event) }

      let!(:bevy_attendee_payload) do
        JSON.parse(File.read(File.join(__dir__, "../fixtures/json/bevy_attendee_payload.json")))
      end

      # Has to use let! otherwise it complains about bevy_attendee_payload being used here
      let!(:bevy_event) do
        Fabricate(
          :bevy_event,
          bevy_event_id: bevy_attendee_payload.first["data"].first["event_id"],
          post: post_event,
        )
      end
      let!(:user) { Fabricate(:user, email: bevy_attendee_payload.first["data"].first["email"]) }
      let!(:user2) { Fabricate(:user, email: bevy_attendee_payload.first["data"].second["email"]) }

      it "creates an invitees and is able to update them" do
        post "/bevy/webhooks.json",
             params: bevy_attendee_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(DiscoursePostEvent::Invitee.count).to eq(2)

        invitees = DiscoursePostEvent::Invitee.all

        expect(invitees.first.user).to eq(user)
        expect(invitees.second.user).to eq(user2)

        expect(invitees.first.status).to eq(DiscoursePostEvent::Invitee.statuses[:going])
        expect(invitees.second.status).to eq(DiscoursePostEvent::Invitee.statuses[:going])

        bevy_attendee_payload.first["data"].first["status"] = "deleted"

        post "/bevy/webhooks.json",
             params: bevy_attendee_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        invitees = invitees.reload

        expect(invitees.first.status).to eq(DiscoursePostEvent::Invitee.statuses[:not_going])
        expect(invitees.second.status).to eq(DiscoursePostEvent::Invitee.statuses[:going])
      end
    end
  end
end
