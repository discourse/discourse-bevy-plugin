# frozen_string_literal: true

BevyPlugin::Engine.routes.draw { post "/webhooks" => "webhooks#receive" }

Discourse::Application.routes.append { mount ::BevyPlugin::Engine, at: "/bevy" }
