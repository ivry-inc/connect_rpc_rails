# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module ConnectRpcRails
  # Base class for unary interceptors. Override #call and invoke
  # `nxt.call(request, context)` to proceed down the chain. Interceptors wrap the
  # whole dispatch, so cross-cutting concerns (auth, logging, instrumentation) are
  # defined once and apply to every RPC uniformly.
  class Interceptor
    #: (untyped, Context, ^(untyped, Context) -> untyped) -> untyped
    def call(request, context, nxt)
      nxt.call(request, context)
    end
  end
end
