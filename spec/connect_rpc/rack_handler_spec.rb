# frozen_string_literal: true

RSpec.describe ConnectRpc::RackHandler do
  let(:client) { Rack::MockRequest.new(described_class.new(build_dispatcher(with_auth: true))) }

  it "round-trips a JSON unary call with a valid bearer token" do
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request(idempotency_key: "json-1"))

    res = rpc_post(client, "IngestUsage", body, content_type: "application/json", bearer: "valid-token")

    expect(res.status).to eq(200)
    expect(res.headers["content-type"]).to eq("application/json")
    decoded = Billing::V1::IngestUsageResponse.decode_json(res.body)
    expect(decoded.usage_event_id).to eq("evt_json-1")
    expect(decoded.accepted).to be(true)
  end

  it "round-trips a binary protobuf unary call" do
    body = Billing::V1::IngestUsageRequest.encode(ingest_request(idempotency_key: "proto-1"))

    res = rpc_post(client, "IngestUsage", body, content_type: "application/proto", bearer: "valid-token")

    expect(res.status).to eq(200)
    expect(res.headers["content-type"]).to eq("application/proto")
    expect(Billing::V1::IngestUsageResponse.decode(res.body).usage_event_id).to eq("evt_proto-1")
  end

  it "returns unauthenticated (401) when the bearer token is missing" do
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request)

    res = rpc_post(client, "IngestUsage", body, content_type: "application/json")

    expect(res.status).to eq(401)
    expect(JSON.parse(res.body)["code"]).to eq("unauthenticated")
  end

  it "maps a domain invalid_argument to HTTP 400" do
    body = Billing::V1::IngestUsageRequest.encode_json(ingest_request(quantity: 0))

    res = rpc_post(client, "IngestUsage", body, content_type: "application/json", bearer: "valid-token")

    expect(res.status).to eq(400)
    expect(JSON.parse(res.body)["code"]).to eq("invalid_argument")
  end

  it "returns 404 for an unknown route (client infers the code)" do
    res = rpc_post(client, "Nope", "{}", content_type: "application/json", bearer: "valid-token")

    expect(res.status).to eq(404)
  end

  it "returns 415 for an unsupported content-type" do
    res = rpc_post(client, "IngestUsage", "x", content_type: "text/plain", bearer: "valid-token")

    expect(res.status).to eq(415)
  end

  it "returns 405 for a non-POST request" do
    res = client.get("/#{BillingHelpers::SERVICE_NAME}/IngestUsage")

    expect(res.status).to eq(405)
  end
end
