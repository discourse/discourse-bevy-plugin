# frozen_string_literal: true

module BevyPlugin
  module TagExtractor
    def self.extract_tags_from_event(event)
      tags = BevyPlugin::JmesTagExtractor.extract_tags_from_data(event)
      tags.compact.uniq
    end
  end
end
