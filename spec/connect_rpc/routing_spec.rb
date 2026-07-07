# frozen_string_literal: true

require "action_dispatch"

# The routes map to "greet#<action>", so the resolved controller must exist.
class GreetController < ActionController::API
  include ConnectRpc::Controller
  connect_service Greet::V1::SERVICE_DESCRIPTOR, handler: Greet::V1::GreetHandler.new
end

RSpec.describe ConnectRpc::Routing do
  let(:routes) do
    ActionDispatch::Routing::RouteSet.new.tap do |set|
      set.draw do
        ConnectRpc::Routing.mount(self, GreetController)
      end
    end
  end

  it "routes POST /<pkg.Service>/<Method> to <controller>#<underscored_method>" do
    expect(routes.recognize_path("/greet.v1.GreetService/SayHello", method: :post))
      .to eq(controller: "greet", action: "say_hello")
  end

  it "does not route an unknown method (host router returns 404)" do
    expect { routes.recognize_path("/greet.v1.GreetService/Nope", method: :post) }
      .to raise_error(ActionController::RoutingError)
  end

  it "routes a non-POST verb to the action too (the controller answers 405)" do
    expect(routes.recognize_path("/greet.v1.GreetService/SayHello", method: :get))
      .to eq(controller: "greet", action: "say_hello")
  end
end
