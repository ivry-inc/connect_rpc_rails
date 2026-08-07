# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "action_dispatch"

# The routes map to "greet#<action>", so the resolved controller must exist.
class GreetController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc
  connect_service GreetHelpers::SERVICE_NAME
end

RSpec.describe ConnectRpcRails::Routing do
  def draw(&block)
    ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&block) }
  end

  let(:routes) { draw { connect_service GreetHelpers::SERVICE_NAME => :greet } }

  it "routes POST /<pkg.Service>/<Method> to <controller>#<underscored_method>" do
    expect(routes.recognize_path("/greet.v1.GreetService/SayHello", method: :post))
      .to eq(controller: "greet", action: "say_hello")
  end

  it "routes a non-POST verb to the action too (the controller answers 405)" do
    expect(routes.recognize_path("/greet.v1.GreetService/SayHello", method: :get))
      .to eq(controller: "greet", action: "say_hello")
  end

  it "sends a method the descriptor never declared to the catch-all" do
    expect(routes.recognize_path("/greet.v1.GreetService/Nope", method: :post))
      .to eq(controller: "greet", action: "connect_unknown_method", connect_method: "Nope")
  end

  it "leaves paths outside the service prefix unrouted" do
    expect { routes.recognize_path("/other.v1.OtherService/SayHello", method: :post) }
      .to raise_error(ActionController::RoutingError)
  end

  it "refuses a service the descriptor pool doesn't hold" do
    expect { draw { connect_service "nope.v1.NopeService" => :greet } }
      .to raise_error(ArgumentError, /no service nope.v1.NopeService in the descriptor pool/)
  end

  describe ".verify_controller!" do
    it "accepts a controller serving the routed service" do
      expect { described_class.verify_controller!(GreetHelpers::SERVICE_NAME, "greet") }.not_to raise_error
    end

    it "refuses a controller serving a different service" do
      expect { described_class.verify_controller!("other.v1.OtherService", "greet") }
        .to raise_error(ArgumentError, /serves greet.v1.GreetService, not other.v1.OtherService/)
    end

    it "refuses a controller that isn't a Connect service at all" do
      stub_const("PlainController", Class.new(ActionController::API))

      expect { described_class.verify_controller!(GreetHelpers::SERVICE_NAME, "plain") }
        .to raise_error(ArgumentError, /does not serve a Connect service/)
    end
  end
end
