# frozen_string_literal: true

module BevyPlugin
  class EventProcessor
    def initialize(event_data)
      @event_data = event_data
    end

    def process
      return [] if @event_data.empty?

      results = []
      errors = []

      @event_data.each do |event|
        case event[:status]
        when "Canceled"
          post = cancel_event(event)
          if post
            topic = post.topic
            results << build_result(topic, event)
          else
            cleanup_orphaned_bevy_event(event[:id])
            Rails.logger.warn("Bevy webhook: Cannot cancel non-existent event #{event[:id]}")
          end
        when "Published"
          if event[:is_hidden] == true || event[:is_test] == true
            delete_event_and_topic(event[:id])
            Rails.logger.info(
              "Bevy webhook: Skipping hidden/test event #{event[:id]}, removed topic if it existed",
            )
            next
          end

          post = create_or_update_event(event)

          topic = post.topic
          results << build_result(topic, event)
        else
          Rails.logger.info(
            "Bevy webhook: Skipping event #{event[:id]} with status #{event[:status]}",
          )
        end
      rescue => e
        Rails.logger.error(
          "Failed to process event #{event[:id]}: #{e.message}\n#{e.backtrace.first(5).join("\n")}",
        )
        errors << { error: e.message, bevy_event_id: event[:id] }
      end

      errors.any? ? results + errors : results
    end

    private

    def cancel_event(event)
      update_event_post(event, edit_reason: "Canceled from Bevy webhook", allow_creation: false)
    end

    def create_or_update_event(event)
      update_event_post(event, edit_reason: "Updated from Bevy webhook", allow_creation: true)
    end

    def update_event_post(event, edit_reason:, allow_creation:)
      bevy_event =
        ::BevyEvent.find_or_create_by!(bevy_event_id: event[:id]) do |bevy_event|
          bevy_event.bevy_updated_ts = Time.parse(event[:updated_ts])
        end

      topic_title = event[:title]
      topic_content = ContentBuilder.new(event).build
      tags = TagExtractor.extract_tags_from_event(event)

      if bevy_event && bevy_event.post_id
        update_existing_post(bevy_event, topic_title, topic_content, tags, edit_reason)
      elsif allow_creation
        create_new_post(event, bevy_event, topic_title, topic_content, tags)
      else
        nil
      end
    end

    def update_existing_post(bevy_event, topic_title, topic_content, tags, edit_reason)
      post = Post.find(bevy_event.post_id)
      topic = post.topic

      revisor = PostRevisor.new(post, topic)
      revisor.revise!(
        post.user,
        title: topic_title,
        raw: topic_content,
        tags: tags,
        edit_reason: edit_reason,
      )

      post
    end

    def create_new_post(event, bevy_event, topic_title, topic_content, tags)
      user = find_or_create_user(event)

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

    def find_or_create_user(event)
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

    def cleanup_orphaned_bevy_event(event_id)
      bevy_event = ::BevyEvent.find_by(bevy_event_id: event_id)
      bevy_event&.destroy if bevy_event && bevy_event.post_id.nil?
    end

    def delete_event_and_topic(event_id)
      bevy_event = ::BevyEvent.find_by(bevy_event_id: event_id)
      return unless bevy_event

      if bevy_event.post_id
        post = Post.find_by(id: bevy_event.post_id)
        if post
          topic = post.topic
          PostDestroyer.new(Discourse.system_user, post).destroy
          Rails.logger.info("Bevy webhook: Deleted topic #{topic.id} for hidden event #{event_id}")
        end
      end

      bevy_event.destroy
    end

    def build_result(topic, event)
      {
        topic_id: topic.id,
        topic_url: "#{Discourse.base_url}/t/#{topic.slug}/#{topic.id}",
        bevy_event_id: event[:id],
        status: event[:status],
      }
    end
  end
end
