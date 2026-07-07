# frozen_string_literal: true
# rbs_inline: enabled

module ConnectRpc
  # Base class for unary interceptors. Override #call and invoke
  # `nxt.call(request, context)` to proceed down the chain. Interceptors run
  # identically for every transport, so cross-cutting concerns (auth, logging)
  # are defined once and apply to both the wire and in-process paths.
  class Interceptor
    #: (untyped, Context, ^(untyped, Context) -> untyped) -> untyped
    def call(request, context, nxt)
      nxt.call(request, context)
    end
  end
end
