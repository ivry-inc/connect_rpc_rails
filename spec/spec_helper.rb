# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rack/mock"
require "connect_rpc"

require_relative "../examples/billing/billing_pb"
require_relative "../examples/billing/billing_handler"
require_relative "../examples/billing/auth_interceptor"

# Keep controller instrumentation quiet in specs.
ActionController::Base.logger = nil

# Shared fixtures/helpers for exercising the example billing service through a
# ConnectRpc::Controller.
module BillingHelpers
  SERVICE_NAME = "billing.v1.BillingService"
  VERIFIER = ->(token) { token == "valid-token" ? "realm:99" : nil }

  def ingest_request(**overrides)
    Billing::V1::IngestUsageRequest.new(
      payer_external_id: "company:1234",
      product: "fax",
      metric: "pages",
      quantity: 3,
      idempotency_key: "k1",
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
  config.include BillingHelpers
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
