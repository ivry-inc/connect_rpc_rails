# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

class GreetRpcController < ActionController::API
  include ConnectRpcRails::Controller

  connect_service Greet::V1::SERVICE_DESCRIPTOR,
    handler: Greet::V1::GreetHandler.new,
    interceptors: [Greet::V1::AuthInterceptor.new(&GreetHelpers::VERIFIER)]
end

RSpec.describe ConnectRpcRails::Controller do
  it "round-trips a JSON unary call with a valid bearer token" do
    body = Greet::V1::SayHelloRequest.encode_json(say_hello_request(name: "Ada"))

    status, headers, resp = call_connect(GreetRpcController, "SayHello", body, content_type: "application/json", bearer: "valid-token")

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")
    decoded = Greet::V1::SayHelloResponse.decode_json(resp)
    expect(decoded.greeting).to eq("Hola, Ada!")
  end

  it "round-trips a binary protobuf unary call" do
    body = Greet::V1::SayHelloRequest.encode(say_hello_request(name: "Grace", preferred_language: "fr"))

    status, headers, resp = call_connect(GreetRpcController, "SayHello", body, content_type: "application/proto", bearer: "valid-token")

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/proto")
    expect(Greet::V1::SayHelloResponse.decode(resp).greeting).to eq("Bonjour, Grace!")
  end

  it "returns unauthenticated (401) when the bearer token is missing" do
    body = Greet::V1::SayHelloRequest.encode_json(say_hello_request)

    status, _headers, resp = call_connect(GreetRpcController, "SayHello", body, content_type: "application/json")

    expect(status).to eq(401)
    expect(JSON.parse(resp)["code"]).to eq("unauthenticated")
  end

  it "maps a domain invalid_argument to HTTP 400" do
    body = Greet::V1::SayHelloRequest.encode_json(say_hello_request(name: ""))

    status, _headers, resp = call_connect(GreetRpcController, "SayHello", body, content_type: "application/json", bearer: "valid-token")

    expect(status).to eq(400)
    expect(JSON.parse(resp)["code"]).to eq("invalid_argument")
  end

  it "returns 415 for an unsupported content-type" do
    status, = call_connect(GreetRpcController, "SayHello", "x", content_type: "text/plain", bearer: "valid-token")

    expect(status).to eq(415)
  end

  it "returns 405 for a non-POST verb" do
    env = Rack::MockRequest.env_for("/#{GreetHelpers::SERVICE_NAME}/SayHello", method: "GET")

    status, = GreetRpcController.action("say_hello").call(env)

    expect(status).to eq(405)
  end

  it "emits process_action.action_controller with the Connect method and the decoded request in params" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    body = Greet::V1::SayHelloRequest.encode_json(say_hello_request)

    call_connect(GreetRpcController, "SayHello", body, content_type: "application/json", bearer: "valid-token")
    ActiveSupport::Notifications.unsubscribe(subscriber)

    payload = events.last.payload
    expect(payload[:connect_method]).to eq("greet.v1.GreetService/SayHello")
    expect(payload[:status]).to eq(200)
    expect(payload[:format]).to eq(:json)
    # params come from the codec's single decode (protobuf snake_case symbol keys),
    # not a second JSON parse by Rails (which would be "preferredLanguage").
    expect(payload[:params]).to include(preferred_language: "es")
  end
end
