# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "google/protobuf/well_known_types"
require "uri"

module Conformance
  V1 = Connectrpc::Conformance::V1

  # Implements connectrpc.conformance.v1.ConformanceService against the
  # connect_rpc_rails library. Mixed into the controller, so the RPCs are its actions
  # and every request gets a fresh instance. Only Unary and IdempotentUnary are implemented.
  # IdempotentUnary is declared free of side effects, so the suite calls it with Connect GET.
  # The rest (streaming, the suite's Unimplemented method) answer `unimplemented`, which is
  # what the suite expects of a server that does not serve them.
  module ServiceImplementation
    def unary = respond_unary(V1::UnaryResponse)

    def idempotent_unary = respond_unary(V1::IdempotentUnaryResponse)

    private def respond_unary(response_class)
      message = connect_request
      definition = message.response_definition
      apply_response_metadata(definition) if definition
      sleep(definition.response_delay_ms / 1000.0) if definition&.response_delay_ms&.positive?
      request_info = request_info_for([message])

      raise error_from(definition.error, request_info) if definition && !definition.error.nil?

      response_class.new(
        payload: V1::ConformancePayload.new(
          data: definition ? definition.response_data : "".b,
          request_info: request_info,
        ),
      )
    end

    # The service contract requires the request info to be echoed even on errors,
    # attached as an error detail alongside any details from the definition.
    private def error_from(error, request_info)
      code = error.code.to_s.delete_prefix("CODE_").downcase.to_sym
      details = error.details.to_a + [Google::Protobuf::Any.pack(request_info)]
      ConnectRpcRails::Error.new(code, error.message, details:)
    end

    private def request_info_for(messages)
      V1::ConformancePayload::RequestInfo.new(
        request_headers: headers(connect_metadata),
        requests: messages.map { |message| Google::Protobuf::Any.pack(message) },
        timeout_ms: connect_timeout_ms,
        connect_get_info:,
      )
    end

    # The suite compares a GET's query parameters with what it sent only when they are echoed.
    private def connect_get_info
      return unless request.get?

      params = URI.decode_www_form(request.query_string).group_by(&:first)
      V1::ConformancePayload::ConnectGetInfo.new(
        query_params: params.map { |name, pairs| V1::Header.new(name:, value: pairs.map(&:last)) },
      )
    end

    # Leading metadata is just the response headers; trailing metadata goes through
    # `connect_trailers`, which encodes Connect's unary `trailer-` form. Rack joins
    # repeated headers with a newline, which is how multi-value metadata is sent.
    private def apply_response_metadata(definition)
      definition.response_headers.each { |header| response.headers[header.name] = header.value.to_a.join("\n") }
      definition.response_trailers.each { |header| connect_trailers[header.name] = header.value.to_a }
    end

    private def headers(metadata)
      metadata.map { |name, value| V1::Header.new(name:, value: [value]) }
    end
  end
end
