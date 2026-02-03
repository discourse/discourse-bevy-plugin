# frozen_string_literal: true

module BevyPlugin
  class ContentBuilder
    def initialize(event)
      @event = event
    end

    def build
      parts = []

      start_date = parse_date(@event[:start_date])
      end_date = parse_date(@event[:end_date])

      add_event_image(parts)
      add_description(parts)
      add_details_section(parts)
      add_rsvp_link(parts) if @event[:status] != "Canceled"
      add_event_metadata(parts, start_date, end_date) if @event[:status] != "Canceled"

      parts.join("\n")
    rescue => e
      Rails.logger.error("Bevy webhook content building error: #{e.message}")
      build_fallback_content
    end

    private

    def parse_date(date_string)
      return nil if date_string.blank?

      Time.parse(date_string).utc
    rescue ArgumentError => e
      Rails.logger.warn("Bevy webhook: Invalid date '#{date_string}': #{e.message}")
      nil
    end

    def add_event_image(parts)
      return if @event.dig(:picture, :url).blank?

      parts << "<div data-bevy-event-image>"
      parts << ""
      parts << "![#{@event[:title]}](#{@event.dig(:picture, :url)})"
      parts << ""
      parts << "</div>"
      parts << ""
    end

    def add_description(parts)
      if @event[:description].present?
        parts << @event[:description]
        parts << ""
      elsif @event[:description_short].present?
        parts << @event[:description_short]
        parts << ""
      end
    end

    def add_details_section(parts)
      parts << "## #{I18n.t("bevy.event.details")}"
      parts << ""

      add_location(parts)
      add_event_type(parts)
      add_chapter(parts)
    end

    def add_location(parts)
      return if @event[:venue_name].blank? && @event[:get_event_address].blank?

      location_line = "**#{I18n.t("bevy.event.where")}:** "
      location_parts = []

      location_parts << @event[:venue_name] if @event[:venue_name].present?
      location_parts << @event[:get_event_address] if @event[:get_event_address].present?

      location_line += location_parts.join(" - ")
      parts << location_line
    end

    def add_event_type(parts)
      return if @event[:event_type_title].blank?

      parts << "**#{I18n.t("bevy.event.type")}:** #{@event[:event_type_title]}"
    end

    def add_chapter(parts)
      return if @event.dig(:chapter, :chapter_location).blank?

      parts << "**#{I18n.t("bevy.event.chapter")}:** #{@event.dig(:chapter, :chapter_location)}"
    end

    def add_rsvp_link(parts)
      return if @event[:url].blank?

      parts << ""
      parts << "[#{I18n.t("bevy.event.view_and_rsvp")}](#{@event[:url]})"
    end

    def add_event_metadata(parts, start_date, end_date)
      return if !start_date && !end_date

      start_date_str = start_date.strftime("%Y-%m-%d %H:%M")
      end_date_str = end_date.strftime("%Y-%m-%d %H:%M")

      parts << %{<div class="discourse-post-event" data-start="#{start_date_str}" data-end="#{end_date_str}" data-timezone="UTC" data-status="public"></div>}
      parts << ""
    end

    def build_fallback_content
      fallback_parts = []
      fallback_parts << @event[:description_short] if @event[:description_short].present?
      if @event[:url].present?
        fallback_parts << "[#{I18n.t("bevy.event.view_event_on_bevy")}](#{@event[:url]})"
      end

      raise "Cannot build content: event data is insufficient" if fallback_parts.empty?

      Rails.logger.warn("Bevy webhook: Using fallback content for event #{@event[:id]}")
      fallback_parts.join("\n\n")
    rescue StandardError => e
      Rails.logger.error("Bevy webhook: Fallback content also failed for event #{@event[:id]}")
      raise e
    end
  end
end
