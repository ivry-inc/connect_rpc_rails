# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "google/protobuf/well_known_types"

module Conformance
  V1 = Connectrpc::Conformance::V1

  # Implements connectrpc.conformance.v1.ConformanceService against the
  # connect_rpc_rails library. Only Unary is implemented; the rest raise unimplemented
  # (streaming and the Connect GET variant are out of scope for this unary
  # library, and are excluded by conformance/config.yaml).
  class ServiceHandler
    def unary(request, context)
      definition = request.response_definition
      apply_response_metadata(definition, context) if definition
      sleep(definition.response_delay_ms / 1000.0) if definition&.response_delay_ms&.positive?
      request_info = request_info_for([request], context)

      raise error_from(definition.error, request_info) if definition && !definition.error.nil?

      V1::UnaryResponse.new(
        payload: V1::ConformancePayload.new(
          data: definition ? definition.response_data : "".b,
          request_info: request_info,
        ),
      )
    end

    def idempotent_unary(_request, _context)
      raise ConnectRpcRails::Error.new(:unimplemented, "the Connect GET variant is not supported")
    end

    def server_stream(_request, _context) = raise_streaming
    def client_stream(_request, _context) = raise_streaming
    def bidi_stream(_request, _context) = raise_streaming
    def unimplemented(_request, _context) = raise ConnectRpcRails::Error.new(:unimplemented, "unimplemented")

    private def raise_streaming
      raise ConnectRpcRails::Error.new(:unimplemented, "streaming is not supported")
    end

    # The service contract requires the request info to be echoed even on errors,
    # attached as an error detail alongside any details from the definition.
    private def error_from(error, request_info)
      code = error.code.to_s.delete_prefix("CODE_").downcase.to_sym
      details = error.details.to_a + [Google::Protobuf::Any.pack(request_info)]
      ConnectRpcRails::Error.new(code, error.message, details:)
    end

    private def request_info_for(requests, context)
      V1::ConformancePayload::RequestInfo.new(
        request_headers: headers(context.metadata),
        requests: requests.map { |request| Google::Protobuf::Any.pack(request) },
        timeout_ms: context.timeout_ms,
      )
    end

    private def apply_response_metadata(definition, context)
      definition.response_headers.each { |header| context.response_headers[header.name] = header.value.to_a }
      definition.response_trailers.each { |header| context.response_trailers[header.name] = header.value.to_a }
    end

    private def headers(metadata)
      metadata.map { |name, value| V1::Header.new(name:, value: [value]) }
    end
  end
end
