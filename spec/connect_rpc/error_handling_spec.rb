# frozen_string_literal: true

# A domain exception the handler knows nothing about the transport for.
class DemoTimeout < StandardError; end

# Interceptor that raises a domain exception, to exercise mapping/propagation.
class BoomInterceptor < ConnectRpc::Interceptor
  def call(_request, _context, _nxt)
    raise DemoTimeout, "upstream timed out"
  end
end

RSpec.describe "error handling via interceptors" do
  include BillingHelpers

  # ExceptionMappingInterceptor must be outermost so it wraps the raiser.
  def dispatcher_with(*interceptors)
    ConnectRpc::Dispatcher.new(interceptors: interceptors)
      .register(Billing::V1::SERVICE_DESCRIPTOR, Billing::V1::BillingHandler.new)
  end

  describe "a mapped exception" do
    let(:dispatcher) do
      mapper = ConnectRpc::ExceptionMappingInterceptor.new(DemoTimeout => :unavailable)
      dispatcher_with(mapper, BoomInterceptor.new)
    end

    it "surfaces as a ConnectRpc::Error on the in-process transport" do
      client = ConnectRpc::InProcess.new(dispatcher, BillingHelpers::SERVICE_NAME, values: {principal: "realm:1"})

      expect { client.call("IngestUsage", ingest_request) }
        .to raise_error(ConnectRpc::Error) { |e| expect(e.code).to eq(:unavailable) }
    end

    it "surfaces as the mapped HTTP status on the wire transport" do
      body = Billing::V1::IngestUsageRequest.encode_json(ingest_request)
      res = rpc_post(
        Rack::MockRequest.new(ConnectRpc::RackHandler.new(dispatcher)),
        "IngestUsage",
        body,
        content_type: "application/json",
      )

      expect(res.status).to eq(503)
      expect(JSON.parse(res.body)["code"]).to eq("unavailable")
    end
  end

  describe "an unmapped exception" do
    let(:dispatcher) { dispatcher_with(BoomInterceptor.new) }

    it "propagates untouched to the caller (in-process)" do
      client = ConnectRpc::InProcess.new(dispatcher, BillingHelpers::SERVICE_NAME, values: {principal: "realm:1"})

      expect { client.call("IngestUsage", ingest_request) }.to raise_error(DemoTimeout)
    end

    it "propagates untouched to the host middleware (wire)" do
      body = Billing::V1::IngestUsageRequest.encode_json(ingest_request)
      client = Rack::MockRequest.new(ConnectRpc::RackHandler.new(dispatcher))

      expect { rpc_post(client, "IngestUsage", body, content_type: "application/json") }
        .to raise_error(DemoTimeout)
    end
  end
end

RSpec.describe ConnectRpc::Result do
  it "reports success and carries the message" do
    result = described_class.success(:payload)

    expect(result.success?).to be(true)
    expect(result.message).to eq(:payload)
  end

  it "reports failure and carries the error" do
    error = ConnectRpc::Error.new(:not_found)
    result = described_class.failure(error)

    expect(result.success?).to be(false)
    expect(result.error).to be(error)
  end
end

RSpec.describe "deadline enforcement" do
  include BillingHelpers

  it "fails with deadline_exceeded when the deadline has already passed" do
    context = ConnectRpc::Context.new(deadline: Time.now - 1)
    result = build_dispatcher.invoke(BillingHelpers::SERVICE_NAME, "IngestUsage", ingest_request, context)

    expect(result.success?).to be(false)
    expect(result.error.code).to eq(:deadline_exceeded)
  end
end
