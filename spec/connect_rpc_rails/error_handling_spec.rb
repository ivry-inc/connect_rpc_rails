# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

# A domain exception the RPC knows nothing about the transport for.
class DemoTimeout < StandardError; end

# The RPC raises the domain exception, so the mapping is what turns it into a wire error.
module BoomRpc
  def say_hello
    raise DemoTimeout, "upstream timed out"
  end
end

class MappedErrorController < ActionController::API
  include ConnectRpcRails::Controller
  include BoomRpc
  connect_service GreetHelpers::SERVICE_NAME
  map_connect_errors DemoTimeout => :unavailable
end

class UnmappedErrorController < ActionController::API
  include ConnectRpcRails::Controller
  include BoomRpc
  connect_service GreetHelpers::SERVICE_NAME
end

# An around_action that outlasts a tight deadline: the library's own around_action is
# declared first, so this one nests inside it and the timeout still fires.
class SlowController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc
  connect_service GreetHelpers::SERVICE_NAME

  around_action :dawdle

  private def dawdle
    sleep(0.2)
    yield
  end
end

# Sets response metadata in a callback, then raises — the error response must still carry
# both. Leading metadata is plain `response.headers`; trailers go through the helper that
# encodes Connect's unary `trailer-` form.
class MetadataErrorController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc
  connect_service GreetHelpers::SERVICE_NAME

  before_action :annotate_and_fail

  private def annotate_and_fail
    response.headers["x-custom-header"] = "hval"
    connect_trailers["x-custom-trailer"] = ["tval"]
    raise ConnectRpcRails::Error.new(:invalid_argument, "boom")
  end
end

# A before_action reads the decoded request, which is what lets a callback do the work an
# interceptor used to: the body is decoded before the callbacks run.
class RejectingController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc
  connect_service GreetHelpers::SERVICE_NAME

  before_action :reject_ada

  private def reject_ada
    raise ConnectRpcRails::Error.new(:permission_denied, "no") if connect_request.name == "Ada"
  end
end

# Raises exceptions Rails itself classifies in `config.action_dispatch.rescue_responses`,
# which no `map_connect_errors` entry here names.
class RescueResponseController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc
  connect_service GreetHelpers::SERVICE_NAME

  # A subclass of a classified exception: rescue_from matches it, so the code has to be
  # found on the nearest classified ancestor rather than on the class itself.
  class TooManyGreetings < ActionController::TooManyRequests; end

  before_action :fail_the_way_the_caller_asked

  private def fail_the_way_the_caller_asked
    raise TooManyGreetings if connect_request.name == "Flood"
    raise ActionController::ParameterMissing, :name if connect_request.name == "Missing"
  end
end

# Overrides the code a rescue_responses entry would otherwise have got.
class OverridingController < ActionController::API
  include ConnectRpcRails::Controller
  include SayHelloRpc
  connect_service GreetHelpers::SERVICE_NAME
  map_connect_errors ActionController::ParameterMissing => :not_found

  before_action :fail

  private def fail
    raise ActionController::ParameterMissing, :name
  end
end

RSpec.describe "error handling" do
  def json_body(**overrides)
    Greet::V1::SayHelloRequest.encode_json(say_hello_request(**overrides))
  end

  it "maps a configured exception to its Connect HTTP status" do
    status, _headers, resp = call_connect(MappedErrorController, "SayHello", json_body, content_type: "application/json")

    expect(status).to eq(503)
    expect(JSON.parse(resp)["code"]).to eq("unavailable")
  end

  it "propagates an unmapped exception to the host middleware" do
    expect { call_connect(UnmappedErrorController, "SayHello", json_body, content_type: "application/json") }
      .to raise_error(DemoTimeout)
  end

  it "gives an exception Rails already classifies a Connect code with no mapping declared" do
    status, _headers, resp = call_connect(
      RescueResponseController, "SayHello", json_body(name: "Missing"), content_type: "application/json"
    )

    expect(status).to eq(400)
    expect(JSON.parse(resp)["code"]).to eq("invalid_argument")
  end

  it "reads the code off the nearest classified ancestor for a subclass" do
    status, _headers, resp = call_connect(
      RescueResponseController, "SayHello", json_body(name: "Flood"), content_type: "application/json"
    )

    expect(status).to eq(429)
    expect(JSON.parse(resp)["code"]).to eq("resource_exhausted")
  end

  it "lets map_connect_errors override the code a classified exception would have got" do
    status, _headers, resp = call_connect(OverridingController, "SayHello", json_body, content_type: "application/json")

    expect(status).to eq(404)
    expect(JSON.parse(resp)["code"]).to eq("not_found")
  end

  it "enforces connect-timeout-ms as a deadline_exceeded error" do
    status, _headers, resp = call_connect(SlowController, "SayHello", json_body, content_type: "application/json", timeout_ms: 10)

    expect(status).to eq(504)
    expect(JSON.parse(resp)["code"]).to eq("deadline_exceeded")
  end

  it "sends response headers and trailers even on an error" do
    status, headers, = call_connect(MetadataErrorController, "SayHello", json_body, content_type: "application/json")

    expect(status).to eq(400)
    expect(headers["x-custom-header"]).to eq("hval")
    expect(headers["trailer-x-custom-trailer"]).to eq("tval")
  end

  it "lets a before_action read the decoded request" do
    status, _headers, resp = call_connect(RejectingController, "SayHello", json_body(name: "Ada"), content_type: "application/json")

    expect(status).to eq(403)
    expect(JSON.parse(resp)["code"]).to eq("permission_denied")
  end

  it "runs the RPC when the same before_action passes" do
    status, _headers, resp = call_connect(RejectingController, "SayHello", json_body(name: "Grace"), content_type: "application/json")

    expect(status).to eq(200)
    expect(Greet::V1::SayHelloResponse.decode_json(resp).greeting).to eq("Hola, Grace!")
  end
end
