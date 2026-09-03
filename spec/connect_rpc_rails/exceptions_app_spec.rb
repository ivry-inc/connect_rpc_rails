# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "google/protobuf/well_known_types"

# Stands in for the host's own exceptions app, so a request this one must not answer is
# visible as having reached what it wraps.
class RecordingExceptionsApp
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def call(_env)
    @calls += 1
    [500, {"content-type" => "application/problem+json"}, ['{"title":"host"}']]
  end
end

# Adds a detail to every escaped exception, the way a host that stamps its errors with a
# request id would.
class DetailedExceptionsApp < ConnectRpcRails::ExceptionsApp
  private def connect_error_for(exception, env)
    error = super
    ConnectRpcRails::Error.new(error.code, error.message, details: error.details + [detail(env)])
  end

  private def detail(env)
    Google::Protobuf::Any.pack(Greet::V1::SayHelloRequest.new(name: env["action_dispatch.request_id"]))
  end
end

RSpec.describe(ConnectRpcRails::ExceptionsApp) do
  let(:host_app) { RecordingExceptionsApp.new }
  let(:app) { described_class.new(host_app) }

  # The env ActionDispatch::ShowExceptions hands its exceptions app: the original request,
  # plus the exception it caught.
  def exceptions_env(exception:, connect: true, **overrides)
    env = Rack::MockRequest.env_for(
      "/#{GreetHelpers::SERVICE_NAME}/SayHello",
      method: "POST",
      "CONTENT_TYPE" => "application/json",
    )
    env["HTTP_CONNECT_PROTOCOL_VERSION"] = "1" if connect
    env["action_dispatch.exception"] = exception if exception
    env.merge(overrides)
  end

  def wire_body(response)
    JSON.parse(response[2].join)
  end

  describe "requests it does not answer" do
    it "passes a request carrying no connect-protocol-version to the wrapped app" do
      response = app.call(exceptions_env(exception: RuntimeError.new("boom"), connect: false))

      expect(host_app.calls).to(eq(1))
      expect(response[1]["content-type"]).to(eq("application/problem+json"))
    end

    it "passes an env with no exception to the wrapped app" do
      app.call(exceptions_env(exception: nil))

      expect(host_app.calls).to(eq(1))
    end
  end

  describe "an exception Rails does not classify" do
    subject(:response) { app.call(exceptions_env(exception: RuntimeError.new("connection string leaked"))) }

    it "renders internal as a Connect JSON error body" do
      expect(response[0]).to(eq(500))
      expect(response[1]["content-type"]).to(eq("application/json"))
      expect(wire_body(response)).to(eq({"code" => "internal", "message" => "Internal Server Error"}))
      expect(host_app.calls).to(eq(0))
    end

    it "sends the status text rather than the exception message" do
      expect(response[2].join).not_to(include("connection string leaked"))
    end

    it "sets a content-length matching the body" do
      expect(response[1]["content-length"]).to(eq(response[2].join.bytesize.to_s))
    end
  end

  it "reads the code off the status rescue_responses assigns the exception" do
    response = app.call(exceptions_env(exception: ActionController::RoutingError.new("no route")))

    expect(response[0]).to(eq(404))
    expect(wire_body(response)).to(eq({"code" => "not_found", "message" => "Not Found"}))
  end

  it "sends an escaped ConnectRpcRails::Error under its own code, message and details" do
    detail = Google::Protobuf::Any.pack(Greet::V1::SayHelloRequest.new(name: "Ada"))
    error = ConnectRpcRails::Error.new(:resource_exhausted, "slow down", details: [detail])

    response = app.call(exceptions_env(exception: error))

    expect(response[0]).to(eq(429))
    expect(wire_body(response)).to(match({
      "code" => "resource_exhausted",
      "message" => "slow down",
      "details" => [{"type" => "greet.v1.SayHelloRequest", "value" => be_a(String)}],
    }))
  end

  # ActionDispatch::ShowExceptions is what actually reaches the exceptions app, and it
  # rewrites the env on the way (PATH_INFO becomes the status) before doing so. This is the
  # wiring the unit examples above assume.
  it "answers an exception escaping a Connect controller when reached through ShowExceptions" do
    raising = ->(_env) { raise(ActionController::BadRequest, "unreadable") }
    stack = ActionDispatch::ShowExceptions.new(raising, app)

    response = stack.call(exceptions_env(exception: nil))

    expect(response[0]).to(eq(400))
    expect(wire_body(response)).to(eq({"code" => "invalid_argument", "message" => "Bad Request"}))
    expect(host_app.calls).to(eq(0))
  end

  it "lets a subclass add details to an exception it did not classify itself" do
    response = DetailedExceptionsApp.new(host_app).call(
      exceptions_env(exception: RuntimeError.new("boom"), "action_dispatch.request_id" => "req-1"),
    )

    expect(wire_body(response)).to(include("code" => "internal"))
    detail = wire_body(response).fetch("details").first
    decoded = Greet::V1::SayHelloRequest.decode(detail.fetch("value").unpack1("m"))
    expect(decoded.name).to(eq("req-1"))
  end
end
