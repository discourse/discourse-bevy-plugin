# frozen_string_literal: true

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

      it "can use extra fields to create a bevy_event and topic with an event" do
        bevy_event_payload.first["data"].first["description"] = "Updated Event Title"

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
        expect(bevy_event_topic.first_post.raw).to include(
          bevy_event_payload.first["data"].first["description"],
        )

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

        expect {
          post "/bevy/webhooks.json",
               params: updated_payload.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)
        }.to not_change { Topic.count }.and(not_change { BevyEvent.count })

        topic.reload
        expect(topic.title).to eq("Updated Event Title")
        expect(topic.first_post.raw).to include("Updated description")

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

        expect(tag_names).to include("virtual")
      end

      it "updates tags when event is updated" do
        SiteSetting.bevy_events_tag_rules = "has-venue,venue_name"

        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        topic = Topic.last
        expect(topic.tags.pluck(:name)).to include("has-venue")

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
        expect(topic.tags.pluck(:name)).not_to include("has-venue")
      end

      it "allows retry when BevyEvent exists but topic creation failed" do
        payload_data = bevy_event_payload.first["data"].first
        timestamp = Time.parse(payload_data["updated_ts"])

        bevy_event =
          BevyEvent.create!(bevy_event_id: payload_data["id"], bevy_updated_ts: timestamp)

        expect(bevy_event.post_id).to be_nil
        expect(BevyEvent.count).to eq(1)
        expect(Topic.count).to eq(0)

        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)
        expect(BevyEvent.count).to eq(1)
        expect(Topic.count).to eq(1)

        bevy_event.reload
        expect(bevy_event.post_id).to be_present
        expect(bevy_event.post.topic.title).to eq(payload_data["title"])
      end

      it "rejects webhook with same timestamp when event was successfully processed" do
        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)
        expect(BevyEvent.count).to eq(1)
        expect(Topic.count).to eq(1)

        bevy_event = BevyEvent.last
        expect(bevy_event.post_id).to be_present

        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(404)
        expect(BevyEvent.count).to eq(1)
        expect(Topic.count).to eq(1)
      end

      it "processes webhook with newer timestamp even when post exists" do
        post "/bevy/webhooks.json",
             params: bevy_event_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)
        original_topic = Topic.last

        updated_payload = bevy_event_payload.deep_dup
        updated_payload.first["data"].first["title"] = "Updated Title"
        updated_payload.first["data"].first["updated_ts"] = (Time.now + 1.hour).to_s

        post "/bevy/webhooks.json",
             params: updated_payload.to_json,
             headers: {
               "X-BEVY-SECRET": "test",
               CONTENT_TYPE: "application/json",
             }

        expect(response.status).to eq(200)
        expect(Topic.count).to eq(1)
        original_topic.reload
        expect(original_topic.title).to eq("Updated Title")
      end

      context "when event status is Canceled" do
        it "updates existing event when status is changed to Canceled" do
          post "/bevy/webhooks.json",
               params: bevy_event_payload.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)
          topic = Topic.last
          original_raw = topic.first_post.raw

          expect(original_raw).to include("discourse-post-event")
          expect(original_raw).to include("View and RSVP")

          bevy_event = BevyEvent.last

          canceled_payload = bevy_event_payload.deep_dup
          canceled_payload.first["data"].first["status"] = "Canceled"
          canceled_payload.first["data"].first["title"] = "CANCELED: My Event Title"
          canceled_payload.first["data"].first["updated_ts"] = (Time.now + 1.hour).to_s

          expect {
            post "/bevy/webhooks.json",
                 params: canceled_payload.to_json,
                 headers: {
                   "X-BEVY-SECRET": "test",
                   CONTENT_TYPE: "application/json",
                 }
          }.to not_change { Topic.count }.and(not_change { BevyEvent.count })

          expect(response.status).to eq(200)
          response_data = response.parsed_body

          expect(response_data["success"]).to be true
          expect(response_data["topics"]).to be_present
          expect(response_data["topics"].first["status"]).to eq("Canceled")
          expect(response_data["topics"].first["bevy_event_id"]).to eq(
            bevy_event_payload.first["data"].first["id"],
          )

          topic.reload
          expect(topic.title).to eq("CANCELED: My Event Title")

          expect(topic.first_post.raw).not_to include("discourse-post-event")
          expect(topic.first_post.raw).not_to include("View and RSVP")

          expect(topic.first_post.revisions.last.modifications["edit_reason"].last).to eq(
            "Canceled from Bevy webhook",
          )

          expect(bevy_event.reload.post.topic.id).to eq(topic.id)
        end

        it "does not create a new topic for a canceled event that doesn't exist" do
          canceled_payload = bevy_event_payload.deep_dup
          canceled_payload.first["data"].first["status"] = "Canceled"
          canceled_payload.first["data"].first["id"] = 999_999

          post "/bevy/webhooks.json",
               params: canceled_payload.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)
          response_data = response.parsed_body

          expect(response_data["success"]).to be true
          expect(response_data["topics"]).to be_empty

          expect(Topic.count).to eq(0)
          expect(BevyEvent.find_by(bevy_event_id: 999_999)).to be_nil
        end

        it "preserves event description and venue details when canceled" do
          event_with_description = bevy_event_payload.deep_dup
          event_with_description.first["data"].first["description"] =
            "This is the full event description with important details."

          post "/bevy/webhooks.json",
               params: event_with_description.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)
          topic = Topic.last

          expect(topic.first_post.raw).to include("This is the full event description")

          canceled_payload = event_with_description.deep_dup
          canceled_payload.first["data"].first["status"] = "Canceled"
          canceled_payload.first["data"].first["updated_ts"] = (Time.now + 1.hour).to_s

          post "/bevy/webhooks.json",
               params: canceled_payload.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)

          topic.reload
          expect(topic.first_post.raw).to include("This is the full event description")
          expect(topic.first_post.raw).to include("Boca Juniors")

          expect(topic.first_post.raw).not_to include("discourse-post-event")
        end

        it "removes the Bevy URL from canceled events" do
          post "/bevy/webhooks.json",
               params: bevy_event_payload.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)
          topic = Topic.last
          payload_url = bevy_event_payload.first["data"].first["url"]

          expect(topic.first_post.raw).to include(payload_url)

          canceled_payload = bevy_event_payload.deep_dup
          canceled_payload.first["data"].first["status"] = "Canceled"
          canceled_payload.first["data"].first["updated_ts"] = (Time.now + 1.hour).to_s

          post "/bevy/webhooks.json",
               params: canceled_payload.to_json,
               headers: {
                 "X-BEVY-SECRET": "test",
                 CONTENT_TYPE: "application/json",
               }

          expect(response.status).to eq(200)

          topic.reload
          expect(topic.first_post.raw).not_to include(payload_url)
        end
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
