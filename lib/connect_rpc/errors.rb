# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module ConnectRpc
  # A Connect protocol error. The code set and its HTTP status mapping are defined
  # by the spec (https://connectrpc.com/docs/protocol/). Handlers raise these; the
  # transport turns them into the wire error body.
  class Error < StandardError
    CODE_TO_HTTP_STATUS = {
      canceled: 499,
      unknown: 500,
      invalid_argument: 400,
      deadline_exceeded: 504,
      not_found: 404,
      already_exists: 409,
      permission_denied: 403,
      resource_exhausted: 429,
      failed_precondition: 400,
      aborted: 409,
      out_of_range: 400,
      unimplemented: 501,
      internal: 500,
      unavailable: 503,
      data_loss: 500,
      unauthenticated: 401,
    }.freeze #: Hash[Symbol, Integer]

    attr_reader :code #: Symbol
    attr_reader :details #: Array[untyped]

    #: (Symbol, ?String?, ?details: Array[untyped]) -> void
    def initialize(code, message = nil, details: [])
      raise ArgumentError, "unknown Connect error code: #{code.inspect}" unless CODE_TO_HTTP_STATUS.key?(code)

      @code = code
      @details = details
      super(message || code.to_s)
    end

    #: () -> Integer
    def http_status
      CODE_TO_HTTP_STATUS.fetch(@code)
    end

    #: () -> Hash[Symbol, untyped]
    def to_wire
      body = {code: @code.to_s, message: message}
      body[:details] = @details.map { |any| encode_detail(any) } unless @details.empty?
      body
    end

    # A detail is a google.protobuf.Any; its Connect wire form is the bare message
    # type name plus the serialized bytes as unpadded standard base64.
    private def encode_detail(any)
      {
        type: any.type_url.split('/').last,
        value: [any.value].pack('m0').delete('='),
      }
    end
  end
end
