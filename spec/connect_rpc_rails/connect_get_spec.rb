# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require_relative "../support/idempotent_greet_pb"

# Implements SayHello, which the service declares free of side effects, and neither
# SaveGreeting nor WatchGreetings.
class IdempotentGreetController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc

  connect_service IdempotentGreet::SERVICE_NAME
end

RSpec.describe("Connect GET") do
  def say_hello_get(query, controller: IdempotentGreetController)
    call_connect_get(controller, "SayHello", query)
  end

  def json_params(**overrides)
    connect_get_params(say_hello_request(name: "Ada"), encoding: :json).merge(overrides)
  end

  def error_of(body)
    JSON.parse(body).slice("code", "message")
  end

  describe "a side-effect-free RPC" do
    it "round-trips a JSON message from the query string" do
      status, headers, body = say_hello_get(json_params)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(Greet::V1::SayHelloResponse.decode_json(body).greeting).to eq("Hola, Ada!")
    end

    it "round-trips a base64 binary message" do
      message = say_hello_request(name: "Grace", preferred_language: "fr")

      status, headers, body = say_hello_get(connect_get_params(message, encoding: :proto))

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/proto")
      expect(Greet::V1::SayHelloResponse.decode(body).greeting).to eq("Bonjour, Grace!")
    end

    it "accepts padded base64" do
      message = say_hello_request(name: "Grace", preferred_language: "fr")
      padded = [Greet::V1::SayHelloRequest.encode(message)].pack("m0").tr("+/", "-_")

      status, = say_hello_get(connect_get_params(message, encoding: :proto).merge(message: padded))

      expect(padded).to end_with("=")
      expect(status).to eq(200)
    end

    it "accepts a percent-encoded binary message that Rails refuses as a query parameter" do
      message = say_hello_request(name: "a" * 200)
      params = {encoding: "proto", message: Greet::V1::SayHelloRequest.encode(message)}

      status, = say_hello_get(params)

      expect(params[:message].dup.force_encoding(Encoding::UTF_8)).not_to be_valid_encoding
      expect(status).to eq(200)
    end

    it "keeps no other query parameters when Rails cannot parse the query" do
      seen = []
      controller = stub_const("ParamsRecordingGreetController", Class.new(IdempotentGreetController) do
        before_action { seen.concat(params.to_unsafe_h.keys) }
      end)
      message = Greet::V1::SayHelloRequest.encode(say_hello_request(name: "a" * 200))

      status, = say_hello_get({encoding: "proto", message:, page: "2"}, controller:)

      expect(status).to eq(200)
      expect(seen).to include("name")
      expect(seen).not_to include("page")
    end

    it "ignores a base64 value other than 1" do
      status, = say_hello_get(json_params(base64: "0"))

      expect(status).to eq(200)
    end

    it "accepts a request without connect=v1, as typed into an address bar" do
      status, = say_hello_get(json_params.except(:connect))

      expect(status).to eq(200)
    end

    it "treats an empty connect value as absent" do
      status, = say_hello_get(json_params(connect: ""))

      expect(status).to eq(200)
    end

    it "ignores a body sent with the GET, and its content type" do
      env = Rack::MockRequest.env_for(
        "/#{IdempotentGreet::SERVICE_NAME}/SayHello?#{URI.encode_www_form(json_params)}",
        method: "GET",
        input: "garbage",
        "CONTENT_TYPE" => "application/proto",
      )

      status, headers, body = call_action(IdempotentGreetController, "SayHello", env)

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      expect(Greet::V1::SayHelloResponse.decode_json(body).greeting).to eq("Hola, Ada!")
    end

    it "accepts compression=identity" do
      status, = say_hello_get(json_params(compression: "identity"))

      expect(status).to eq(200)
    end

    it "keeps serving POST" do
      body = Greet::V1::SayHelloRequest.encode_json(say_hello_request(name: "Ada"))

      status, = call_connect(IdempotentGreetController, "SayHello", body, content_type: "application/json")

      expect(status).to eq(200)
    end

    it "decodes the message before the controller's callbacks run" do
      seen = []
      controller = stub_const("RecordingGreetController", Class.new(IdempotentGreetController) do
        before_action { seen << connect_request.name }
      end)

      say_hello_get(json_params, controller:)

      expect(seen).to eq(["Ada"])
    end

    it "answers unimplemented when the controller has no action for it" do
      controller = stub_const("UnimplementedIdempotentGreetController", Class.new(ActionController::API) do
        include ConnectRpcRails::Controller

        connect_service IdempotentGreet::SERVICE_NAME
      end)

      status, _, body = say_hello_get(json_params, controller:)

      expect(status).to eq(501)
      expect(error_of(body)).to eq(
        "code" => "unimplemented",
        "message" => "greet.v1.IdempotentGreetService/SayHello is not implemented",
      )
    end

    it "reports the decoded message as params and the encoding as the format" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      message = say_hello_request(name: "Ada")

      say_hello_get(connect_get_params(message, encoding: :proto).merge(page: "2"))
      ActiveSupport::Notifications.unsubscribe(subscriber)

      payload = events.last.payload
      expect(payload[:format]).to eq(:proto)
      expect(payload[:params]).to include(name: "Ada", preferred_language: "es", "page" => "2")
      expect(payload[:params].keys.map(&:to_s)).not_to include(*ConnectRpcRails::GetQuery::PARAMS)
    end
  end

  describe "a request the protocol rejects" do
    it "answers a connect value other than v1 with invalid_argument" do
      status, _, body = say_hello_get(json_params(connect: "v2"))

      expect(status).to eq(400)
      expect(error_of(body)).to eq("code" => "invalid_argument", "message" => "connect query parameter must be v1")
    end

    it "answers a request without a message with invalid_argument" do
      status, _, body = say_hello_get(json_params.except(:message))

      expect(status).to eq(400)
      expect(error_of(body)).to eq("code" => "invalid_argument", "message" => "missing message query parameter")
    end

    it "answers a message that does not decode with invalid_argument, without quoting it" do
      status, _, body = say_hello_get(json_params(message: '{"name": secret-token'))

      expect(status).to eq(400)
      expect(error_of(body)).to eq("code" => "invalid_argument", "message" => "invalid message query parameter")
      expect(body).not_to include("secret-token")
    end

    it "answers standard-alphabet base64 with invalid_argument" do
      status, _, body = say_hello_get(json_params(base64: "1", message: "CgN+ZGE/"))

      expect(status).to eq(400)
      expect(error_of(body)).to eq("code" => "invalid_argument", "message" => "invalid message query parameter")
    end

    it "answers an encoding it has no codec for with 415" do
      unknown, = say_hello_get(json_params(encoding: "xml"))
      missing, = say_hello_get(json_params.except(:encoding))

      expect([unknown, missing]).to eq([415, 415])
    end

    it "answers request compression with unimplemented, advertising identity" do
      status, headers, body = say_hello_get(json_params(compression: "gzip"))

      expect(status).to eq(501)
      expect(headers["accept-encoding"]).to eq("identity")
      expect(error_of(body)).to eq(
        "code" => "unimplemented",
        "message" => 'unsupported compression "gzip": supported encodings are identity',
      )
    end
  end

  describe "an RPC that may have side effects" do
    let(:post_only_controller) do
      stub_const("PostOnlyGreetController", Class.new(ActionController::API) do
        include ConnectRpcRails::Controller
        include SayHelloRpc

        connect_service GreetHelpers::SERVICE_NAME
      end)
    end

    it "answers GET with 405, allowing POST" do
      status, headers, = say_hello_get(json_params, controller: post_only_controller)

      expect(status).to eq(405)
      expect(headers["allow"]).to eq("POST")
    end

    it "answers GET with 405 when it is only IDEMPOTENT, even without an action for it" do
      status, headers, = call_connect_get(IdempotentGreetController, "SaveGreeting", json_params)

      expect(status).to eq(405)
      expect(headers["allow"]).to eq("POST")
    end

    it "answers GET with 405 when it streams, even though it is NO_SIDE_EFFECTS" do
      controller = stub_const("WatchingGreetController", Class.new(IdempotentGreetController) do
        def watch_greetings = Greet::V1::SayHelloResponse.new
      end)

      status, headers, = call_connect_get(controller, "WatchGreetings", json_params)

      expect(status).to eq(405)
      expect(headers["allow"]).to eq("POST")
    end
  end

  it "names GET and POST in the Allow header of a 405 to a side-effect-free RPC" do
    env = Rack::MockRequest.env_for("/#{IdempotentGreet::SERVICE_NAME}/SayHello", method: "DELETE")

    status, headers, = IdempotentGreetController.action("say_hello").call(env)

    expect(status).to eq(405)
    expect(headers["allow"]).to eq("GET, POST")
  end
end
