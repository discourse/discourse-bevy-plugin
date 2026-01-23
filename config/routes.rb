# frozen_string_literal: true

BevyPlugin::Engine.routes.draw do
  scope "/bevy" do
    post "/webhooks" => "webhooks#receive"
  end
end

Discourse::Application.routes.append { mount ::BevyPlugin::Engine, at: "/" }
