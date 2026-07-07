# frozen_string_literal: true

class BillingRpcController < ActionController::API
  include ConnectRpc::Controller

  connect_service Billing::V1::SERVICE_DESCRIPTOR,
    handler: Billing::V1::BillingHandler.new,
    interceptors: [Billing::V1::AuthInterceptor.new(&BillingHelpers::VERIFIER)]
end

RSpec.describe ConnectRpc::Controller do
  it "round-trips a JSON unary call with a valid bearer token" do
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request(idempotency_key: "json-1"))

    status, headers, resp = call_connect(BillingRpcController, "IngestUsage", body, content_type: "application/json", bearer: "valid-token")

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")
    decoded = Billing::V1::IngestUsageResponse.decode_json(resp)
    expect(decoded.usage_event_id).to eq("evt_json-1")
    expect(decoded.accepted).to be(true)
  end

  it "round-trips a binary protobuf unary call" do
    body = Billing::V1::IngestUsageRequest.encode(ingest_request(idempotency_key: "proto-1"))

    status, headers, resp = call_connect(BillingRpcController, "IngestUsage", body, content_type: "application/proto", bearer: "valid-token")

    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/proto")
    expect(Billing::V1::IngestUsageResponse.decode(resp).usage_event_id).to eq("evt_proto-1")
  end

  it "returns unauthenticated (401) when the bearer token is missing" do
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request)

    status, _headers, resp = call_connect(BillingRpcController, "IngestUsage", body, content_type: "application/json")

    expect(status).to eq(401)
    expect(JSON.parse(resp)["code"]).to eq("unauthenticated")
  end

  it "maps a domain invalid_argument to HTTP 400" do
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request(quantity: 0))

    status, _headers, resp = call_connect(BillingRpcController, "IngestUsage", body, content_type: "application/json", bearer: "valid-token")

    expect(status).to eq(400)
    expect(JSON.parse(resp)["code"]).to eq("invalid_argument")
  end

  it "returns 415 for an unsupported content-type" do
    status, = call_connect(BillingRpcController, "IngestUsage", "x", content_type: "text/plain", bearer: "valid-token")

    expect(status).to eq(415)
  end

  it "returns 405 for a non-POST verb" do
    env = Rack::MockRequest.env_for("/#{BillingHelpers::SERVICE_NAME}/IngestUsage", method: "GET")

    status, = BillingRpcController.action("ingest_usage").call(env)

    expect(status).to eq(405)
  end

  it "emits process_action.action_controller with the Connect method and the decoded request in params" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request)

    call_connect(BillingRpcController, "IngestUsage", body, content_type: "application/json", bearer: "valid-token")
    ActiveSupport::Notifications.unsubscribe(subscriber)

    payload = events.last.payload
    expect(payload[:connect_method]).to eq("billing.v1.BillingService/IngestUsage")
    expect(payload[:status]).to eq(200)
    expect(payload[:format]).to eq(:json)
    # params come from the codec's single decode (protobuf snake_case symbol keys),
    # not a second JSON parse by Rails (which would be "payerExternalId").
    expect(payload[:params]).to include(payer_external_id: "company:1234")
  end
end
