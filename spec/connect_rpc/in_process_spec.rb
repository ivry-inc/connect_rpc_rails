# frozen_string_literal: true

RSpec.describe ConnectRpc::InProcess do
  it "reaches the handler without serialization" do
    client = described_class.new(build_dispatcher, BillingHelpers::SERVICE_NAME, values: {principal: "realm:42"})

    response = client.call("IngestUsage", ingest_request(idempotency_key: "inproc-1"))

    expect(response).to be_a(Billing::V1::IngestUsageResponse)
    expect(response.usage_event_id).to eq("evt_inproc-1")
    expect(response.accepted).to be(true)
  end

  it "propagates a domain error as a ConnectRpc::Error" do
    client = described_class.new(build_dispatcher, BillingHelpers::SERVICE_NAME, values: {principal: "realm:42"})

    expect { client.call("IngestUsage", ingest_request(quantity: 0)) }
      .to raise_error(ConnectRpc::Error) { |e| expect(e.code).to eq(:invalid_argument) }
  end

  it "lets a trusted principal bypass the shared auth interceptor" do
    # The same interceptor guards the wire path; a seeded principal short-circuits
    # the bearer check, so no token is needed in-process.
    client = described_class.new(build_dispatcher(with_auth: true), BillingHelpers::SERVICE_NAME, values: {principal: "realm:trusted"})

    response = client.call("IngestUsage", ingest_request(idempotency_key: "trusted-1"))

    expect(response.usage_event_id).to eq("evt_trusted-1")
  end
end
