# frozen_string_literal: true

BevyPlugin::Engine.routes.draw do
  scope "/bevy" do
    post "/webhooks" => "webhooks#receive"
  end

  # Admin routes
  # scope "/admin/plugins/bevy-plugin", constraints: AdminConstraint.new do
  #   get "/" => "admin#index"

  #   scope format: :json do
  #     put "/template" => "admin#update"
  #   end
  # end
end

Discourse::Application.routes.draw { mount ::BevyPlugin::Engine, at: "/" }
