# frozen_string_literal: true

# name: discourse-bevy-plugin
# about: Integration with Bevy event management platform to automatically create event topics
# meta_topic_id: TODO
# version: 0.0.1
# authors: Discourse
# url: https://github.com/yourusername/discourse-bevy-plugin
# required_version: 2.7.0

gem "jmespath", "1.6.2"

enabled_site_setting :bevy_plugin_enabled

add_admin_route "bevy_plugin.admin.title", "bevy-plugin"

module ::BevyPlugin
  PLUGIN_NAME = "discourse-bevy-plugin"
end

require_relative "lib/bevy_plugin/engine"
require_relative "lib/bevy_plugin/jmes_tag_extractor"

after_initialize do
  # Code which should run after Rails has finished booting
end
