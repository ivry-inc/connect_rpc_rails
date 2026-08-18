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

# A service split one controller per RPC declares itself once on the base class, which is
# what makes the per-RPC subclasses resolvable by .verify_controller!.
class GreetBaseController < ActionController::API
  include ConnectRpcRails::Controller
  connect_service GreetHelpers::SERVICE_NAME
end

class GreetSayHelloController < GreetBaseController
  include SayHelloRpc
end

# The example service declares one RPC, which cannot show a mapping that leaves one out.
# This one declares two, reusing the example's message types.
module MultiGreet
  SERVICE_NAME = "greet.v1.MultiGreetService"

  def self.method_descriptor(name)
    Google::Protobuf::MethodDescriptorProto.new(
      name: name,
      input_type: ".greet.v1.SayHelloRequest",
      output_type: ".greet.v1.SayHelloResponse",
    )
  end

  file = Google::Protobuf::FileDescriptorProto.new(
    name: "greet/v1/multi_greet.proto",
    package: "greet.v1",
    syntax: "proto3",
    dependency: ["greet/v1/greet.proto"],
    service: [
      Google::Protobuf::ServiceDescriptorProto.new(
        name: "MultiGreetService",
        method: [method_descriptor("SayHello"), method_descriptor("SayGoodbye")],
      ),
    ],
  )
  Google::Protobuf::DescriptorPool.generated_pool
    .add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
end

class MultiGreetBaseController < ActionController::API
  include ConnectRpcRails::Controller
  connect_service MultiGreet::SERVICE_NAME
end

# Implements SayHello and not SayGoodbye, which the service declares.
class MultiGreetSayHelloController < MultiGreetBaseController
  include SayHelloRpc
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

  describe "a controller per RPC" do
    let(:routes) do
      draw do
        connect_service GreetHelpers::SERVICE_NAME do
          rpc "SayHello" => :greet_say_hello
        end
      end
    end

    it "routes the RPC to the controller it is mapped to" do
      expect(routes.recognize_path("/greet.v1.GreetService/SayHello", method: :post))
        .to eq(controller: "greet_say_hello", action: "say_hello")
    end

    it "draws the catch-all at a controller serving the service" do
      expect(routes.recognize_path("/greet.v1.GreetService/Nope", method: :post))
        .to eq(controller: "greet_say_hello", action: "connect_unknown_method", connect_method: "Nope")
    end

    it "refuses a service the block maps to nothing" do
      expect { draw { connect_service(GreetHelpers::SERVICE_NAME) {} } }
        .to raise_error(ArgumentError, /greet\.v1\.GreetService is mapped to no controller/)
    end

    describe "an RPC the mapping leaves out" do
      let(:routes) do
        draw do
          connect_service MultiGreet::SERVICE_NAME do
            rpc "SayHello" => :multi_greet_say_hello
          end
        end
      end

      it "is routed, so it is not a 404" do
        expect(routes.recognize_path("/greet.v1.MultiGreetService/SayGoodbye", method: :post))
          .to eq(controller: "multi_greet_say_hello", action: "say_goodbye")
      end

      it "is answered unimplemented by the controller it lands on" do
        status, _headers, body = call_connect(
          MultiGreetSayHelloController, "SayGoodbye", "{}", content_type: "application/json"
        )

        expect(status).to eq(501)
        expect(JSON.parse(body)["code"]).to eq("unimplemented")
      end
    end

    it "refuses a mapped name the service does not declare" do
      expect do
        draw do
          connect_service GreetHelpers::SERVICE_NAME do
            rpc "SayHello" => :greet_say_hello
            rpc "SayGoodbye" => :greet_say_goodbye
          end
        end
      end.to raise_error(ArgumentError, /declares no RPC named SayGoodbye/)
    end

    it "refuses a service name with neither a mapping nor a block" do
      expect { draw { connect_service GreetHelpers::SERVICE_NAME } }
        .to raise_error(ArgumentError, /takes a service-to-controller mapping, or a service name with a block/)
    end

    it "refuses a controller mapping passed alongside a block" do
      expect { draw { connect_service(GreetHelpers::SERVICE_NAME => :greet) {} } }
        .to raise_error(ArgumentError, /takes a service name with a block/)
    end

    it "serves the RPC through the subclass that inherits the declaration" do
      status, _headers, body = call_connect(
        GreetSayHelloController, "SayHello", say_hello_request.to_json, content_type: "application/json"
      )

      expect(status).to eq(200)
      expect(JSON.parse(body)).to eq("greeting" => "Hola, Ada Lovelace!")
    end
  end

  it "refuses a service the descriptor pool doesn't hold" do
    expect { draw { connect_service "nope.v1.NopeService" => :greet } }
      .to raise_error(ArgumentError, /no service "nope\.v1\.NopeService" in the descriptor pool/)
  end

  describe ".verify_controller!" do
    it "accepts a controller serving the routed service" do
      expect { described_class.verify_controller!(GreetHelpers::SERVICE_NAME, "greet") }.not_to raise_error
    end

    it "accepts a subclass that inherits the declaration from its base" do
      expect { described_class.verify_controller!(GreetHelpers::SERVICE_NAME, "greet_say_hello") }.not_to raise_error
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
