# frozen_string_literal: true

BevyPlugin::Engine.routes.draw { post "/webhooks" => "webhooks#receive" }

Discourse::Application.routes.draw { mount ::BevyPlugin::Engine, at: "/bevy" }
