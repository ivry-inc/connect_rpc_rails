# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "spec_helper"
require "json"
require "connect_rpc_rails/protovalidate"
require "google/rpc/error_details_pb"
require_relative "../support/validated_greet_pb"

RSpec.describe(ConnectRpcRails::MessageValidatable) do
  def define_controller(&body)
    stub_const("ValidatedGreetController", Class.new(ActionController::API) do
      include ConnectRpcRails::Controller
      include ConnectRpcRails::MessageValidatable

      connect_service "validated.v1.ValidatedGreetService"

      class_eval(&body) if body

      def say_hello
        Validated::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
      end
    end)
  end

  def invalid_request(**fields)
    Validated::V1::SayHelloRequest.new(name: "Ada", preferred_language: "es", **fields)
  end

  def call_json(controller, message, bearer: nil)
    body = Validated::V1::SayHelloRequest.encode_json(message)
    call_connect(controller, "SayHello", body, content_type: "application/json", bearer:)
  end

  def call_proto(controller, message)
    body = Validated::V1::SayHelloRequest.encode(message)
    call_connect(controller, "SayHello", body, content_type: "application/proto")
  end

  def bad_request_of(body)
    wire = JSON.parse(body)
    detail = wire.fetch("details").sole
    expect(detail.fetch("type")).to eq("google.rpc.BadRequest")
    Google::Rpc::BadRequest.decode(detail.fetch("value").unpack1("m"))
  end

  it "answers a rule violation with invalid_argument and a BadRequest" do
    status, _, body = call_json(define_controller, invalid_request(preferred_language: "e"))

    expect(status).to eq(400)
    expect(JSON.parse(body)).to include(
      "code" => "invalid_argument",
      "message" => "preferredLanguage: must be at least 2 characters",
    )
    expect(bad_request_of(body).field_violations.map(&:to_h)).to eq([{
      field: "preferredLanguage",
      reason: "STRING_MIN_LEN",
      description: "must be at least 2 characters",
    }])
  end

  it "reports every violated field" do
    _, _, body = call_json(define_controller, invalid_request(name: "", preferred_language: "e"))

    expect(bad_request_of(body).field_violations.map(&:field)).to eq(["name", "preferredLanguage"])
    expect(JSON.parse(body).fetch("message"))
      .to eq("name: must be at least 1 characters; preferredLanguage: must be at least 2 characters")
  end

  it "names fields by their proto name for a binary request" do
    _, _, body = call_proto(define_controller, invalid_request(preferred_language: "e"))

    expect(bad_request_of(body).field_violations.map(&:field)).to eq(["preferred_language"])
  end

  it "names a repeated element and a map value in the caller's encoding" do
    message = invalid_request(
      parts: [Validated::V1::Part.new(part_name: "ok"), Validated::V1::Part.new],
      labels: {"primary" => Validated::V1::Part.new},
    )

    _, _, json_body = call_json(define_controller, message)
    _, _, proto_body = call_proto(define_controller, message)

    expect(bad_request_of(json_body).field_violations.map(&:field))
      .to eq(["parts[1].partName", 'labels["primary"].partName'])
    expect(bad_request_of(proto_body).field_violations.map(&:field))
      .to eq(["parts[1].part_name", 'labels["primary"].part_name'])
  end

  it "lets a valid request through to the RPC" do
    status, _, body = call_json(define_controller, invalid_request)

    expect(status).to eq(200)
    expect(JSON.parse(body)).to eq({"greeting" => "Hello, Ada!"})
  end

  # Otherwise an unauthenticated caller could probe what a valid body looks like.
  it "runs after the authentication a controller declares above its RPCs" do
    controller = define_controller do
      include BearerAuthentication

      self.token_verifier = GreetHelpers::VERIFIER
    end

    unauthenticated, = call_json(controller, invalid_request(preferred_language: "e"))
    authenticated, = call_json(controller, invalid_request(preferred_language: "e"), bearer: "valid-token")

    expect(unauthenticated).to eq(401)
    expect(authenticated).to eq(400)
  end

  it "stays out of the way of a controller that skips it" do
    controller = define_controller do
      skip_before_action :validate_connect_message!
    end

    status, = call_json(controller, invalid_request(preferred_language: "e"))

    expect(status).to eq(200)
  end

  it "answers with the Connect error the controller builds from the violation" do
    controller = define_controller do
      private def connect_error_for_violation(error)
        ConnectRpcRails::Error.new(
          :failed_precondition, "#{error.violations.size} rule(s) broken by #{error.request_message.class.descriptor.name}"
        )
      end
    end

    status, _, body = call_json(controller, invalid_request(name: "", preferred_language: "e"))

    expect(status).to eq(400)
    expect(JSON.parse(body)).to eq({
      "code" => "failed_precondition",
      "message" => "2 rule(s) broken by validated.v1.SayHelloRequest",
    })
  end

  it "answers with a Connect error caused by the violation" do
    rendered = []
    controller = define_controller do
      define_method(:render_connect_error) do |error|
        rendered << error
        super(error)
      end
      private :render_connect_error
    end

    call_json(controller, invalid_request(preferred_language: "e"))

    cause = rendered.sole.cause
    expect(cause).to be_a(described_class::ViolationError)
    expect(cause.violations.map(&:rule_id)).to eq(["string.min_len"])
    expect(cause.backtrace_locations.first.label).to end_with("validate_connect_message!")
  end

  it "publishes a reason AIP-193 accepts for any rule id" do
    expect(described_class.reason("string.min_len")).to eq("STRING_MIN_LEN")
    expect(described_class.reason("widget-name-shape")).to eq("INVALID_VALUE")
    expect(described_class.reason("")).to eq("INVALID_VALUE")
  end

  it "names what to generate when google.rpc.BadRequest is missing" do
    pool = Google::Protobuf::DescriptorPool.generated_pool
    allow(pool).to receive(:lookup).and_call_original
    allow(pool).to receive(:lookup).with("google.rpc.BadRequest").and_return(nil)

    expect { described_class.googleapis_class("google.rpc.BadRequest") }
      .to raise_error(described_class::MissingDescriptorError, %r{google/rpc/error_details\.proto})
  end
end
