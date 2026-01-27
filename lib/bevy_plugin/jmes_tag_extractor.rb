# frozen_string_literal: true

module ::BevyPlugin
  class JmesTagExtractor
    def self.extract_tags_from_data(data)
      return [] if rules.empty?

      rules
        .select do |_tag, expression|
          result = ::JMESPath.search(expression, data)
          # JMESPath returns truthy/falsy values, we only include tags where expression is truthy
          result && result != false
        end
        .keys
    rescue ::JMESPath::Errors::ParseError => e
      Rails.logger.error("Bevy plugin: JMESPath parsing error: #{e.message}")
      raise
    rescue => e
      Rails.logger.error("Bevy plugin: Error extracting tags: #{e.message}")
      raise
    end

    private

    def self.rules
      @rules_cache ||= {}
      setting_value = SiteSetting.bevy_events_tag_rules
      return {} if setting_value.blank?

      @rules_cache[setting_value] ||=
        setting_value
          .split("|")
          .filter_map do |rule|
            parts = rule.split(",", 2)
            tag_name = parts[0]&.strip
            expression = parts[1]&.strip

            if tag_name.blank? || expression.blank?
              Rails.logger.warn(
                "Bevy plugin: Invalid tag rule format: '#{rule}'. Expected 'tag_name,jmes_expression'",
              )
              next
            end

            [tag_name, expression]
          end
          .to_h
    end
  end
end
