# frozen_string_literal: true

module BevyPlugin
  class AttendeeProcessor
    def initialize(attendee_data)
      @attendee_data = attendee_data
    end

    def process
      post_event_attendees_hash = group_attendees_by_event

      results = []
      timestamp = Time.zone.now

      post_event_attendees_hash.each do |event_id, emails_statuses|
        result = sync_attendees_for_event(event_id, emails_statuses, timestamp)
        results << result if result
      end

      results
    rescue => e
      Rails.logger.error("Failed to process attendees: #{e.message}")
      [{ error: e.message }]
    end

    private

    def group_attendees_by_event
      post_event_attendees_hash = Hash.new { |h, k| h[k] = {} }

      @attendee_data.each do |attendee_data|
        event_id = attendee_data[:event_id]
        post_event_attendees_hash[event_id][attendee_data[:email]] = attendee_data[:status]
      end

      post_event_attendees_hash
    end

    def sync_attendees_for_event(event_id, emails_statuses, timestamp)
      bevy_event = ::BevyEvent.find_by(bevy_event_id: event_id)

      unless bevy_event&.post_id
        Rails.logger.warn("Bevy webhook: No post found for event #{event_id}")
        return nil
      end

      discourse_event = DiscoursePostEvent::Event.find_by(id: bevy_event.post_id)

      unless discourse_event
        Rails.logger.warn("Bevy webhook: No discourse event found for post #{bevy_event.post_id}")
        return nil
      end

      users_by_email = find_users_by_emails(emails_statuses.keys)
      attrs = build_invitee_attributes(users_by_email, emails_statuses, discourse_event.id, timestamp)

      DiscoursePostEvent::Invitee.upsert_all(attrs, unique_by: %i[post_id user_id]) if attrs.any?

      { bevy_event_id: event_id, attendees_synced: attrs.length }
    end

    def find_users_by_emails(emails)
      User
        .joins(:user_emails)
        .where(user_emails: { email: emails })
        .distinct
        .includes(:user_emails)
        .flat_map { |u| u.user_emails.map { |e| [e.email, u] } }
        .to_h
    end

    def build_invitee_attributes(users_by_email, emails_statuses, post_id, timestamp)
      users_by_email.map do |email, user|
        bevy_status = emails_statuses[email].to_sym
        discourse_status = status_map[bevy_status]

        if discourse_status.nil?
          raise "Unknown Bevy attendee status: '#{bevy_status}'. Expected one of: #{status_map.keys.join(", ")}"
        end

        {
          post_id: post_id,
          created_at: timestamp,
          updated_at: timestamp,
          user_id: user.id,
          status: discourse_status,
        }
      end
    end

    def status_map
      {
        registered: DiscoursePostEvent::Invitee.statuses[:going],
        deleted: DiscoursePostEvent::Invitee.statuses[:not_going],
      }
    end
  end
end
