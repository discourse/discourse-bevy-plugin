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
      BevyPlugin::AttendeeProcessor.new(events[:data]).process
    end

    def process_event(events)
      BevyPlugin::EventProcessor.new(events[:data]).process
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
