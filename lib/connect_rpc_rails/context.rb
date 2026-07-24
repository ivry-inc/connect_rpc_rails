# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module ConnectRpcRails
  # Per-invocation context. The Rack transport fills `metadata` from request
  # headers and derives `deadline`/`timeout_ms`.
  #
  # `values` is a generic per-invocation bag (like Twirp's env hash or connect-go's
  # context values) that interceptors, callbacks, and handlers use to pass data —
  # e.g. an auth interceptor writes the authenticated principal and the handler
  # reads it (`context[:principal]`). The library itself never interprets it.
  class Context
    attr_reader :metadata #: Hash[String, String]
    attr_reader :deadline #: Time?
    attr_reader :timeout_ms #: Integer?
    attr_reader :values #: Hash[Symbol, untyped]

    # Response metadata a handler can set. On the wire, response_headers are sent
    # as leading headers and response_trailers as `trailer-`-prefixed headers
    # (Connect's unary form).
    attr_reader :response_headers #: Hash[String, Array[String]]
    attr_reader :response_trailers #: Hash[String, Array[String]]

    #: (?metadata: Hash[String, String], ?deadline: Time?, ?timeout_ms: Integer?, ?values: Hash[Symbol, untyped]) -> void
    def initialize(metadata: {}, deadline: nil, timeout_ms: nil, values: {})
      @metadata = metadata
      @deadline = deadline
      @timeout_ms = timeout_ms
      @values = values
      @response_headers = {}
      @response_trailers = {}
    end

    #: (Symbol) -> untyped
    def [](key) = @values[key]

    #: (Symbol, untyped) -> untyped
    def []=(key, value)
      @values[key] = value
    end
  end
end
