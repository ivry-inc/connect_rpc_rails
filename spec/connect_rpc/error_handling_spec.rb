# frozen_string_literal: true

# A domain exception the handler knows nothing about the transport for.
class DemoTimeout < StandardError; end

# Interceptor that raises a domain exception, to exercise mapping/propagation.
class BoomInterceptor < ConnectRpc::Interceptor
  def call(_request, _context, _nxt)
    raise DemoTimeout, "upstream timed out"
  end
end

# Interceptor that runs longer than a tight deadline.
class SlowInterceptor < ConnectRpc::Interceptor
  def call(request, context, nxt)
    sleep(0.2)
    nxt.call(request, context)
  end
end

# ExceptionMappingInterceptor must be outermost so it wraps the raiser.
class MappedErrorController < ActionController::API
  include ConnectRpc::Controller
  connect_service Billing::V1::SERVICE_DESCRIPTOR,
    handler: Billing::V1::BillingHandler.new,
    interceptors: [ConnectRpc::ExceptionMappingInterceptor.new(DemoTimeout => :unavailable), BoomInterceptor.new]
end

class UnmappedErrorController < ActionController::API
  include ConnectRpc::Controller
  connect_service Billing::V1::SERVICE_DESCRIPTOR,
    handler: Billing::V1::BillingHandler.new,
    interceptors: [BoomInterceptor.new]
end

class SlowController < ActionController::API
  include ConnectRpc::Controller
  connect_service Billing::V1::SERVICE_DESCRIPTOR,
    handler: Billing::V1::BillingHandler.new,
    interceptors: [SlowInterceptor.new]
end

# Sets response metadata, then raises — the error response must still carry it.
class MetadataErrorInterceptor < ConnectRpc::Interceptor
  def call(_request, context, _nxt)
    context.response_headers["x-custom-header"] = ["hval"]
    context.response_trailers["x-custom-trailer"] = ["tval"]
    raise ConnectRpc::Error.new(:invalid_argument, "boom")
  end
end

class MetadataErrorController < ActionController::API
  include ConnectRpc::Controller
  connect_service Billing::V1::SERVICE_DESCRIPTOR,
    handler: Billing::V1::BillingHandler.new,
    interceptors: [MetadataErrorInterceptor.new]
end

RSpec.describe "error handling" do
  def json_body(**overrides)
    Billing::V1::IngestUsageRequest.encode_json(ingest_request(**overrides))
  end

  it "maps a configured exception to its Connect HTTP status" do
    status, _headers, resp = call_connect(MappedErrorController, "IngestUsage", json_body, content_type: "application/json")

    expect(status).to eq(503)
    expect(JSON.parse(resp)["code"]).to eq("unavailable")
  end

  it "propagates an unmapped exception to the host middleware" do
    expect { call_connect(UnmappedErrorController, "IngestUsage", json_body, content_type: "application/json") }
      .to raise_error(DemoTimeout)
  end

  it "enforces connect-timeout-ms as a deadline_exceeded error" do
    status, _headers, resp = call_connect(SlowController, "IngestUsage", json_body, content_type: "application/json", timeout_ms: 10)

    expect(status).to eq(504)
    expect(JSON.parse(resp)["code"]).to eq("deadline_exceeded")
  end

  it "sends handler response headers and trailers even on an error" do
    status, headers, = call_connect(MetadataErrorController, "IngestUsage", json_body, content_type: "application/json")

    expect(status).to eq(400)
    expect(headers["x-custom-header"]).to eq("hval")
    expect(headers["trailer-x-custom-trailer"]).to eq("tval")
  end
end
