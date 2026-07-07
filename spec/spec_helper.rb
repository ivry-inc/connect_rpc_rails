# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rack/mock"
require "connect_rpc"

require_relative "../examples/billing/billing_pb"
require_relative "../examples/billing/billing_handler"
require_relative "../examples/billing/auth_interceptor"

# Shared fixtures/helpers for exercising the example billing service over both
# transports.
module BillingHelpers
  SERVICE_NAME = "billing.v1.BillingService"
  VERIFIER = ->(token) { token == "valid-token" ? "realm:99" : nil }

  def build_dispatcher(with_auth: false)
    interceptors = with_auth ? [Billing::V1::AuthInterceptor.new(&VERIFIER)] : []
    ConnectRpc::Dispatcher.new(interceptors: interceptors)
      .register(Billing::V1::SERVICE_DESCRIPTOR, Billing::V1::BillingHandler.new)
  end

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

  # POST a Connect unary call through a Rack::MockRequest client.
  def rpc_post(client, method, body, content_type:, bearer: nil)
    env = {input: body, "CONTENT_TYPE" => content_type}
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    client.post("/#{SERVICE_NAME}/#{method}", env)
  end
end

RSpec.configure do |config|
  config.include BillingHelpers
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
