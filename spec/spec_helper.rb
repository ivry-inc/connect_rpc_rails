# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rack/mock"
require "connect_rpc"

require_relative "../examples/greet/lib/greet_pb"
require_relative "../examples/greet/app/rpc/greet_handler"
require_relative "../examples/greet/app/rpc/auth_interceptor"

# Keep controller instrumentation quiet in specs.
ActionController::Base.logger = nil

# Shared fixtures/helpers for exercising the example greet service through a
# ConnectRpc::Controller.
module GreetHelpers
  SERVICE_NAME = "greet.v1.GreetService"
  VERIFIER = Greet::V1::TOKEN_VERIFIER

  def say_hello_request(**overrides)
    Greet::V1::SayHelloRequest.new(
      name: "Ada Lovelace",
      preferred_language: "es",
      **overrides,
    )
  end

  # Drive a Connect unary call through a controller's full ActionController
  # lifecycle (callbacks, rescue_from, instrumentation) — no router needed.
  def call_connect(controller, method, body, content_type:, bearer: nil, timeout_ms: nil)
    env = Rack::MockRequest.env_for(
      "/#{SERVICE_NAME}/#{method}",
      method: "POST",
      input: body,
      "CONTENT_TYPE" => content_type,
    )
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    env["HTTP_CONNECT_TIMEOUT_MS"] = timeout_ms.to_s if timeout_ms

    status, headers, proxy = controller.action(ConnectRpc.underscore(method)).call(env)
    collected = +""
    proxy.each { |chunk| collected << chunk }
    [status, headers, collected]
  end
end

RSpec.configure do |config|
  config.include GreetHelpers
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
