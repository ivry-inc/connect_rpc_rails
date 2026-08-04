# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rack/mock"
require "connect_rpc_rails"

# The specs drive Action Controller and Action Dispatch directly, with no Rails app to boot
# the Railtie that would normally do this.
ConnectRpcRails.install!

require_relative "../examples/greet/lib/greet_pb"
require_relative "../examples/greet/app/controllers/concerns/bearer_authentication"

# Keep controller instrumentation quiet in specs.
ActionController::Base.logger = nil

# The greeting logic the spec controllers implement as their own RPC action, mirroring
# the example service (which does the same inline).
module SayHelloRpc
  SALUTATIONS = {"es" => "Hola", "fr" => "Bonjour", "ja" => "こんにちは"}.freeze

  def say_hello
    raise ConnectRpcRails::Error.new(:invalid_argument, "name is required") if connect_request.name.empty?

    salutation = SALUTATIONS.fetch(connect_request.preferred_language, "Hello")
    Greet::V1::SayHelloResponse.new(greeting: "#{salutation}, #{connect_request.name}!")
  end
end

# Shared fixtures/helpers for exercising the example greet service through a
# ConnectRpcRails::Controller.
module GreetHelpers
  SERVICE_NAME = "greet.v1.GreetService"
  # Stand-in for real bearer verification, as in the example service.
  VERIFIER = ->(token) { token == "valid-token" ? "user:99" : nil }

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

    status, headers, proxy = controller.action(ConnectRpcRails.underscore(method)).call(env)
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
