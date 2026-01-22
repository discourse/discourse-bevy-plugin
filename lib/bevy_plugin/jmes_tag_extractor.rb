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
    end

    private

    def self.rules
      setting_value = SiteSetting.bevy_events_jmes_tag_rules
      return {} if setting_value.blank?

      setting_value.split("|").map { |rule| rule.split(",", 2) }.to_h
    end
  end
end
