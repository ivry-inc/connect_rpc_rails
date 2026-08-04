# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module ConnectRpcRails
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

    # Rails keeps its exception taxonomy in HTTP statuses
    # (`config.action_dispatch.rescue_responses`), so reusing it means reading a status back
    # as a Connect code. This is the inverse of CODE_TO_HTTP_STATUS above — the same
    # code↔status pairing `google.rpc.Code` defines, read the other way.
    #
    # It is *not* gRPC's HTTP-to-status mapping
    # (https://grpc.github.io/grpc/core/md_doc_http-grpc-status-mapping.html), and Connect's
    # equivalent table doesn't apply here either. Those describe a client reading an HTTP
    # response that carries no RPC status at all — a proxy's 502, a load balancer's 404 —
    # where 400 means "an intermediary rejected the request" (`internal`) and 404 means "no
    # such service here" (`unimplemented`). Read that way round, a `RecordNotFound` would go
    # out as `unimplemented`, colliding with the one thing that code means on this server: a
    # routed RPC with no action. The table also stops at seven statuses and sends the rest to
    # `unknown`, which is most of what Active Record raises (409, 422).
    #
    # Where several codes share a status, the entry is the one that fits what Rails raises
    # there: 409 is `aborted` for a `StaleObjectError`'s lost race, not `already_exists`; 400
    # is plain `invalid_argument`. Statuses no code claims (405, 406, 415, 422) take the
    # nearest code by meaning.
    HTTP_STATUS_TO_CODE = {
      400 => :invalid_argument,
      401 => :unauthenticated,
      403 => :permission_denied,
      404 => :not_found,
      405 => :unimplemented,
      406 => :invalid_argument,
      409 => :aborted,
      412 => :failed_precondition,
      415 => :invalid_argument,
      422 => :invalid_argument,
      429 => :resource_exhausted,
      499 => :canceled,
      500 => :internal,
      501 => :unimplemented,
      503 => :unavailable,
      504 => :deadline_exceeded,
    }.freeze #: Hash[Integer, Symbol]

    # The Connect code for an HTTP status. Statuses the table doesn't name fall back on
    # their class, so a mapping Rails (or a gem) adds is never left without a code.
    #: (Integer) -> Symbol
    def self.code_for_http_status(status)
      HTTP_STATUS_TO_CODE[status] || (status >= 500 ? :internal : :invalid_argument)
    end

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
      body = {code: @code.to_s, message: message} #: Hash[Symbol, untyped]
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
