# frozen_string_literal: true

Fabricator(:bevy_event) do
  bevy_event_id { sequence(:bevy_event_id) }
  bevy_updated_ts { 10.hours.ago }
  post
end
