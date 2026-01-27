# frozen_string_literal: true

module BevyPlugin
  class WebhooksController < ::ApplicationController
    requires_plugin ::BevyPlugin::PLUGIN_NAME

    skip_before_action :verify_authenticity_token, :redirect_to_login_if_required, :check_xhr

    before_action :filter_unhandled, :ensure_webhook_authenticity, :filter_expired_event

    HANDLED_EVENTS = %w[event attendee]

    def receive
      payload = webhook_payload

      return render json: { error: "Empty payload" }, status: :bad_request if payload.empty?

      results = []
      errors = []

      payload.each do |events|
        result = send("process_#{events[:type]}".to_sym, events)
        if result.is_a?(Hash) && result[:error]
          errors << result
        elsif result.is_a?(Array)
          results.concat(result)
        else
          results << result
        end
      end

      if errors.any? && results.empty?
        render json: { success: false, errors: errors }, status: :internal_server_error
      elsif errors.any?
        render json: {
                 success: true,
                 processed: results.length,
                 topics: results.compact,
                 errors: errors,
               },
               status: :multi_status
      else
        render json: { success: true, processed: results.length, topics: results.compact }
      end
    rescue => e
      Rails.logger.error("Bevy webhook error: #{e.message}\n#{e.backtrace.join("\n")}")
      render json: { error: e.message }, status: :internal_server_error
    end

    private

    def process_attendee(events)
      # Group attendees and status by event_id
      post_event_attendees_hash = Hash.new { |h, k| h[k] = {} }
      events[:data].each do |attendee_data|
        event_id = attendee_data[:event_id]
        post_event_attendees_hash[event_id][attendee_data[:email]] = attendee_data[:status]
      end

      results = []
      timestamp = Time.zone.now

      status_map = {
        registered: DiscoursePostEvent::Invitee.statuses[:going],
        deleted: DiscoursePostEvent::Invitee.statuses[:not_going],
      }

      post_event_attendees_hash.each do |event_id, emails_statuses|
        bevy_event = ::BevyEvent.find_by(bevy_event_id: event_id)
        unless bevy_event&.post_id
          Rails.logger.warn("Bevy webhook: No post found for event #{event_id}")
          next
        end

        # Post events id is the same as the post they belong to
        discourse_event = DiscoursePostEvent::Event.find_by(id: bevy_event.post_id)

        unless discourse_event
          Rails.logger.warn("Bevy webhook: No discourse event found for post #{bevy_event.post_id}")
          next
        end

        users_by_email =
          User
            .joins(:user_emails)
            .where(user_emails: { email: emails_statuses.keys })
            .distinct
            .includes(:user_emails)
            .flat_map { |u| u.user_emails.map { |e| [e.email, u] } }
            .to_h

        attrs =
          users_by_email.map do |email, user|
            bevy_status = emails_statuses[email].to_sym
            discourse_status = status_map[bevy_status]

            if discourse_status.nil?
              raise "Unknown Bevy attendee status: '#{bevy_status}'. Expected one of: #{status_map.keys.join(", ")}"
            end

            {
              post_id: discourse_event.id,
              created_at: timestamp,
              updated_at: timestamp,
              user_id: user.id,
              status: discourse_status,
            }
          end

        DiscoursePostEvent::Invitee.upsert_all(attrs, unique_by: %i[post_id user_id]) if attrs.any?

        results << { bevy_event_id: event_id, attendees_synced: attrs.length }
      end

      results
    rescue => e
      Rails.logger.error("Failed to process attendees: #{e.message}")
      [{ error: e.message }]
    end

    def ensure_webhook_authenticity
      api_key = SiteSetting.bevy_webhook_api_key

      if api_key.blank?
        return render json: { error: "Webhook not configured" }, status: :service_unavailable
      end

      provided_key = request.headers["X-BEVY-SECRET"]

      unless ActiveSupport::SecurityUtils.secure_compare(provided_key.to_s, api_key)
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    end

    def process_event(events)
      return [] if events[:data].empty?

      results = []
      errors = []

      events[:data].each do |event|
        next unless event[:status] == "Published"

        post = find_or_create_event_topic(event)

        topic = post.topic
        result = {
          topic_id: topic.id,
          topic_url: "#{Discourse.base_url}/t/#{topic.slug}/#{topic.id}",
          bevy_event_id: event[:id],
        }

        results << result
      rescue => e
        Rails.logger.error(
          "Failed to create topic for event #{event[:id]}: #{e.message}\n#{e.backtrace.first(5).join("\n")}",
        )
        errors << { error: e.message, bevy_event_id: event[:id] }
      end

      errors.any? ? results + errors : results
    end

    def find_or_create_event_topic(event)
      bevy_event = ::BevyEvent.find_by(bevy_event_id: event[:id])

      topic_title = event[:title]
      topic_content = build_topic_content(event)
      tags = extract_tags_from_event(event)

      if bevy_event && bevy_event.post_id
        post = Post.find(bevy_event.post_id)
        topic = post.topic

        revisor = PostRevisor.new(post, topic)
        revisor.revise!(
          post.user,
          title: topic_title,
          raw: topic_content,
          tags: tags,
          edit_reason: "Updated from Bevy webhook",
        )

        post
      else
        user = find_or_create_using_system_user(event)

        category_id = SiteSetting.bevy_webhook_category_id

        if category_id.blank?
          Rails.logger.warn("Bevy webhook: No category configured, using Uncategorized")
          category_id = SiteSetting.uncategorized_category_id
        end

        post =
          PostCreator.new(
            user,
            title: topic_title,
            raw: topic_content,
            category: category_id,
            tags: tags,
            skip_validations: true,
            skip_bot: true,
          ).create

        bevy_event.post_id = post.id
        bevy_event.save

        post
      end
    end

    def find_or_create_using_system_user(event)
      published_by = event[:published_by]

      if published_by && published_by[:email].present?
        user = User.find_by_email(published_by[:email])
        return user if user

        Rails.logger.info(
          "Bevy webhook: User not found for email #{published_by[:email]}, using system",
        )
      end

      User.find(Discourse.system_user.id)
    end

    def build_topic_content(event)
      parts = []

      start_date = nil
      end_date = nil

      begin
        start_date = Time.parse(event[:start_date]).utc if event[:start_date].present?
      rescue ArgumentError => e
        Rails.logger.warn("Bevy webhook: Invalid start_date for event #{event[:id]}: #{e.message}")
      end

      begin
        end_date = Time.parse(event[:end_date]).utc if event[:end_date].present?
      rescue ArgumentError => e
        Rails.logger.warn("Bevy webhook: Invalid end_date for event #{event[:id]}: #{e.message}")
      end

      if event.dig(:picture, :url).present?
        parts << "<div data-bevy-event-image>"
        parts << ""
        parts << "![#{event[:title]}](#{event.dig(:picture, :url)})"
        parts << ""
        parts << "</div>"
        parts << ""
      end

      if event[:description_short].present?
        parts << event[:description_short]
        parts << ""
      end

      parts << "## #{I18n.t("bevy.event.details")}"
      parts << ""

      if event[:venue_name].present? || event[:get_event_address].present?
        location_line = "**#{I18n.t("bevy.event.where")}:** "
        location_parts = []

        location_parts << event[:venue_name] if event[:venue_name].present?
        location_parts << event[:get_event_address] if event[:get_event_address].present?

        location_line += location_parts.join(" - ")
        parts << location_line
      end

      if event[:event_type_title].present?
        parts << "**#{I18n.t("bevy.event.type")}:** #{event[:event_type_title]}"
      end

      if event.dig(:chapter, :chapter_location).present?
        parts << "**#{I18n.t("bevy.event.chapter")}:** #{event.dig(:chapter, :chapter_location)}"
      end

      parts << ""

      if start_date
        start_date_str = start_date.strftime("%Y-%m-%d %H:%M")
        end_date_str = end_date.strftime("%Y-%m-%d %H:%M") if end_date

        parts << %{<div class="discourse-post-event" data-start="#{start_date_str}" data-end="#{end_date_str}" data-timezone="UTC" data-status="public"></div>}
        parts << ""
      end

      if event[:url].present?
        parts << "---"
        parts << ""
        parts << "[#{I18n.t("bevy.event.view_and_rsvp")}](#{event[:url]})"
      end

      parts.join("\n")
    rescue => e
      Rails.logger.error("Bevy webhook content building error: #{e.message}")

      # Try fallback to basic content, but if that fails too, re-raise
      begin
        fallback_parts = []
        fallback_parts << event[:description_short] if event[:description_short].present?
        if event[:url].present?
          fallback_parts << "[#{I18n.t("bevy.event.view_event_on_bevy")}](#{event[:url]})"
        end

        raise "Cannot build content: event data is insufficient" if fallback_parts.empty?

        Rails.logger.warn("Bevy webhook: Using fallback content for event #{event[:id]}")
        fallback_parts.join("\n\n")
      rescue StandardError
        Rails.logger.error("Bevy webhook: Fallback content also failed for event #{event[:id]}")
        raise e
      end
    end

    def extract_tags_from_event(event)
      tags = BevyPlugin::JmesTagExtractor.extract_tags_from_data(event)
      tags.compact.uniq
    end

    def filter_unhandled
      payload = webhook_payload
      return if payload.empty?

      has_handled_event = payload.any? { |event_data| HANDLED_EVENTS.include?(event_data[:type]) }
      raise Discourse::NotFound unless has_handled_event
    end

    def filter_expired_event
      payload = webhook_payload
      return if payload.empty?

      payload.each do |event_data|
        next unless event_data[:type] == "event"

        event_data[:data]&.each do |event|
          next unless event[:id] && event[:updated_ts]

          begin
            updated_ts = Time.parse(event[:updated_ts])
          rescue ArgumentError
            Rails.logger.warn("Bevy webhook: Invalid updated_ts for event #{event[:id]}")
            next
          end

          begin
            existing_event =
              ::BevyEvent.find_or_create_by!(bevy_event_id: event[:id]) do |bevy_event|
                bevy_event.bevy_updated_ts = updated_ts
              end

            if existing_event.post_id.present? && existing_event.bevy_updated_ts >= updated_ts
              Rails.logger.info(
                "Bevy webhook: Skipping outdated event #{event[:id]} (timestamp: #{updated_ts})",
              )
              raise Discourse::NotFound
            elsif !existing_event.new_record?
              existing_event.update!(bevy_updated_ts: updated_ts)
            end
          rescue ActiveRecord::RecordNotUnique
            retry
          end
        end
      end

      true
    rescue Discourse::NotFound
      raise
    rescue => e
      Rails.logger.error("Bevy webhook filter_expired_event error: #{e.message}")
      true
    end

    def webhook_payload
      @webhook_payload ||=
        begin
          payload = params[:_json]
          return [] unless payload

          # For each item, permit :type and allow all nested data
          # We use .permit! on data since event payloads have arbitrary nested structure
          payload.map do |item|
            permitted_item = item.permit(:type)
            permitted_item[:data] = item[:data].map(&:permit!) if item[:data]
            permitted_item.to_h.deep_symbolize_keys
          end
        end
    end
  end
end
