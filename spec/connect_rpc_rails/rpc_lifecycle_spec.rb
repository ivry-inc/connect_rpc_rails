# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "action_dispatch"

# Reports what the *previous* call left on the instance, so a response echoing an
# earlier caller's name would be state leaking between requests.
class LeakyController < ActionController::API
  include ConnectRpcRails::Controller
  connect_service GreetHelpers::SERVICE_NAME

  def say_hello
    previous = @previous_name
    @previous_name = connect_request.name
    Greet::V1::SayHelloResponse.new(greeting: previous.to_s)
  end
end

# Registers the service but implements nothing, so every RPC of it is routed to an action
# that doesn't exist.
class UnimplementedController < ActionController::API
  include ConnectRpcRails::Controller
  connect_service GreetHelpers::SERVICE_NAME
end

RSpec.describe "RPC instance lifecycle" do
  def say_hello(controller, name)
    body = Greet::V1::SayHelloRequest.encode_json(say_hello_request(name: name))
    status, _headers, resp = call_connect(controller, "SayHello", body, content_type: "application/json")
    [status, resp]
  end

  # Which answer an unserved method gets depends on how it was routed, so these go through
  # a RouteSet rather than straight at the controller action.
  def call_routed(controller_path, method)
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { connect_service GreetHelpers::SERVICE_NAME => controller_path }
    env = Rack::MockRequest.env_for(
      "/#{GreetHelpers::SERVICE_NAME}/#{method}",
      method: "POST",
      input: Greet::V1::SayHelloRequest.encode_json(say_hello_request),
      "CONTENT_TYPE" => "application/json",
    )

    status, _headers, proxy = routes.call(env)
    collected = +""
    proxy.each { |chunk| collected << chunk }
    [status, collected]
  end

  it "runs the RPC the controller implements as its action" do
    status, resp = say_hello(LeakyController, "Ada")

    expect(status).to eq(200)
    expect(Greet::V1::SayHelloResponse.decode_json(resp).greeting).to eq("")
  end

  it "gives each request its own controller instance, so nothing leaks to the next caller" do
    say_hello(LeakyController, "Ada")
    _status, resp = say_hello(LeakyController, "Grace")

    expect(Greet::V1::SayHelloResponse.decode_json(resp).greeting).to eq("")
  end

  it "answers a declared but unimplemented method with unimplemented (501)" do
    status, resp = call_routed("unimplemented", "SayHello")

    expect(status).to eq(501)
    expect(JSON.parse(resp)["code"]).to eq("unimplemented")
    expect(JSON.parse(resp)["message"]).to eq("greet.v1.GreetService/SayHello is not implemented")
  end

  it "answers a method the service never declared with a 404, not unimplemented" do
    status, = call_routed("leaky", "Nope")

    expect(status).to eq(404)
  end

  it "leaves an action that is neither an RPC nor routed as a Rails ActionNotFound" do
    env = Rack::MockRequest.env_for("/nope", method: "POST")

    expect { LeakyController.action("nope").call(env) }
      .to raise_error(AbstractController::ActionNotFound)
  end
end
