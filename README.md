# connect_rpc (prototype)

A minimal [Connect](https://connectrpc.com/docs/protocol/) **unary** RPC server for
Rails, built on `ActionController::API`. Built to validate whether a Connect-for-Ruby
layer is small enough to own, given that `google-protobuf` and `grpc` are already in
the stack and `crossbar-rp` already provides bearer auth.

## The one idea

A Connect service is an `ActionController::API` controller: `connect_service`
generates **one Rails action per RPC method**, so every call flows through the normal
controller lifecycle. That is the whole point — `process_action.action_controller`
fires, so the entire Rails observability ecosystem (Datadog resource naming, Sentry
transactions, lograge, the `Completed 200 in Xms` request log) works with no extra
wiring. The domain logic stays a plain Ruby **handler**; the generated action is a
thin adapter.

```
caller ──HTTP──▶ Rails router ──▶ BillingController#ingest_usage ──▶ handler (PORO)
                                  (ConnectRpc::Controller: decode ▸ interceptors ▸ encode)
```

```ruby
class BillingController < ActionController::API
  include ConnectRpc::Controller
  connect_service Billing::V1::SERVICE_DESCRIPTOR,
    handler: Billing::V1::BillingHandler.new,
    interceptors: [Billing::V1::AuthInterceptor.new(&VERIFIER)]
end

# config/routes.rb — 1 RPC = 1 action, so an unknown method is a plain 404.
ConnectRpc::Routing.mount(self, BillingController)
```

**Why `ActionController::API`, not a bare Rack transport?** An earlier cut had its own
`Dispatcher`/`RackHandler` and PORO-only handlers. It was dropped: going off the
controller path means losing everything that hangs off `process_action.action_controller`
(Datadog/Sentry/lograge/the request log) and rebuilding each integration by hand.
`ActionController::API` ships exactly the useful modules (`Instrumentation`, `Logging`,
`Rescue`, `AbstractController::Callbacks`, `StrongParameters`) and omits the browser
concerns an RPC endpoint never uses (CSRF, cookies, flash, view rendering). The handler
stays a PORO holding domain logic, so it's still trivially unit-testable.

## Context and values

`Context` carries request `metadata`, the deadline, response headers/trailers, and a
generic **`values`** bag (`context[:key]`) — the same idea as Twirp's env hash or
connect-go's context values. The library never interprets `values`; an authenticated
identity is just a convention (`context[:principal]`) that an auth interceptor writes
and a handler reads. There is deliberately no native "principal".

Two composable layers of cross-cutting logic:

- **Interceptors** wrap the decoded `(request, context)` and run for every RPC on the
  controller — the transport-agnostic seam for auth, exception mapping, timing.
- **`ActionController` callbacks** (`before_action`/`around_action`) are available on the
  controller natively — use them for HTTP-level concerns. (The old bespoke
  `ConnectRpc::Callbacks` module is gone; Rails already provides this.)

## Error handling

`ConnectRpc::Error` maps to its Connect code + HTTP status. The controller declares
`rescue_from ConnectRpc::Error` once, so it becomes the wire error body `{code,message,details}`
in exactly one place. An exception that isn't a `ConnectRpc::Error` propagates to the
host's error middleware, per the "let exceptions propagate" policy.

Mapping *arbitrary* exceptions (domain, framework) to Connect codes is the job of an
interceptor, so it applies to every RPC uniformly. A configurable one ships with the
library:

```ruby
connect_service Billing::V1::SERVICE_DESCRIPTOR,
  handler: Billing::V1::BillingHandler.new,
  interceptors: [
    ConnectRpc::ExceptionMappingInterceptor.new(
      ActiveRecord::RecordNotFound => :not_found,
      MyDomain::Invalid            => :invalid_argument,
    ),
    # ...your other interceptors
  ]
```

It rescues only the configured classes (never a blanket rescue); anything unmapped
propagates.

## Deadlines and params

- **`connect-timeout-ms`** is enforced as a deadline by an `around_action`, so the whole
  action (decode + interceptors + handler) runs under it; expiry becomes `deadline_exceeded`.
- **No double body parse.** A Connect action decodes the body itself and never reads
  `params`, so the controller skips Rails' lazy body param parsing. The JSON body isn't
  deserialized twice, and request payloads don't leak into `params`/logs.

## Conformance

The official [connectrpc/conformance](https://github.com/connectrpc/conformance) suite
lives in [`conformance/`](conformance/) and passes **86/86** (Connect + unary) against
the `ActionController::API` transport, with the server-under-test mounted through an
`ActionDispatch` `RouteSet` — including error details, response headers/trailers (on
success *and* error), `connect-timeout-ms` enforcement, and the HTTP-status mapping for
malformed requests (404 unknown method, 405 wrong verb, 415 unsupported media type,
`unimplemented` for unsupported compression). Streaming, gRPC/gRPC-Web, compression, and
TLS remain out of scope. This is the real interop check that hand-written specs can't give.

## What the prototype proves

- **Reflection-based dispatch, no codegen.** A `protoc`/`buf`-generated service lands in the descriptor pool as a `ServiceDescriptor` whose `MethodDescriptor`s expose input/output message classes. `connect_service` generates the actions purely off that — no per-service generated stubs. (`examples/billing/billing_pb.rb` builds the descriptor in pure Ruby so the demo runs with no protoc toolchain.)
- **Rails instrumentation for free.** `process_action.action_controller` fires for every RPC (including errors), carrying `controller`/`action`/`status` plus a `connect_method` payload key (`pkg.Service/Method`) for clean trace/log resource naming.
- **authN vs authZ split.** `AuthInterceptor` (stands in for `crossbar-rp` bearer verification) authenticates the `Bearer` token and writes the principal onto the context `values` bag; the handler reads `context[:principal]` for authorization (realm/payer scoping).
- **Connect wire compliance for unary:** `POST /pkg.Service/Method`, `application/json` + `application/proto`, error body `{code,message,details}` with the spec's code→HTTP-status table.

## Layout

```
lib/connect_rpc/
  controller.rb           # the ActionController::API transport (mix-in)
  routing.rb              # route helper: 1 RPC = 1 action
  service_registration.rb # descriptor -> handler binding (reflection)
  codec.rb                # JSON / proto, via google-protobuf
  context.rb  interceptor.rb  exception_mapping_interceptor.rb  errors.rb
examples/billing/         # example service, handler, auth interceptor
spec/                     # RSpec: controller, routing, auth, error mapping
```

## Run

```sh
rspec          # specs (controller, routing, auth, error mapping, deadline)
rubocop        # Shopify ruleset
rake rbs       # regenerate + validate sig/generated from inline annotations
```

## Types

The library carries [rbs-inline](https://github.com/soutaro/rbs-inline) annotations
(`# rbs_inline: enabled`, `#:` method signatures). `rake rbs` transpiles them into
`sig/generated/**/*.rbs` and runs `rbs validate`. Protobuf messages are typed
`untyped` — in a real setup their `.rbs` comes from buf's `rbs` plugin. Note
rbs-inline is a prototype the maintainer is folding into the `rbs` gem itself, but
the annotation syntax is what will land there.

## Deliberately out of scope

Streaming (enveloped framing), gRPC / gRPC-Web compatibility, request compression,
and the idempotent-GET variant. Unary over the Connect protocol is the whole surface
here; add the rest only when a real consumer needs it.
