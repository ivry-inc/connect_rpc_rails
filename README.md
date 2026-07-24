# connect_rpc

A minimal [Connect](https://connectrpc.com/docs/protocol/) **unary** RPC server for
Rails, built on `ActionController::API`. It gives you a Connect-for-Ruby layer that is
small enough to own outright: a service is an ordinary Rails controller, so it reuses
`google-protobuf` and the observability you already have rather than shipping a parallel
stack.

## How it works

A Connect service is an `ActionController::API` controller: `connect_service`
generates **one Rails action per RPC method**, so every call flows through the normal
controller lifecycle. Because `process_action.action_controller` fires, the entire
Rails observability ecosystem (Datadog resource naming, Sentry transactions, lograge,
the `Completed 200 in Xms` request log) works with no extra wiring. The domain logic
stays a plain Ruby **handler**; the generated action is a thin adapter.

```
caller ──HTTP──▶ Rails router ──▶ GreetController#say_hello ──▶ handler (PORO)
                                  (ConnectRpc::Controller: decode ▸ interceptors ▸ encode)
```

```ruby
# app/controllers/greet_controller.rb
class GreetController < ActionController::API
  include ConnectRpc::Controller
  connect_service Greet::V1::SERVICE_DESCRIPTOR,
    handler: Greet::V1::GreetHandler.new,
    interceptors: [Greet::V1::AuthInterceptor.new(&Greet::V1::TOKEN_VERIFIER)]
end
```

```ruby
# config/routes.rb — 1 RPC = 1 route, so an unknown method is a plain 404.
Rails.application.routes.draw do
  ConnectRpc::Routing.mount(self, GreetController)
end
```

The handler is a plain object under `app/rpc/`; nothing about it is HTTP- or
Rails-aware, so it stays trivially unit-testable:

```ruby
# app/rpc/greet_handler.rb
module Greet
  module V1
    class GreetHandler
      def say_hello(request, context)
        # context[:principal] was set by the auth interceptor; authZ lives here.
        SayHelloResponse.new(greeting: "Hello, #{request.name}!")
      end
    end
  end
end
```

**Why `ActionController::API`, not a bare Rack transport?** A bespoke Rack transport
would mean going off the controller path and losing everything that hangs off
`process_action.action_controller` (Datadog/Sentry/lograge/the request log), then
rebuilding each integration by hand. `ActionController::API` ships exactly the useful
modules (`Instrumentation`, `Logging`, `Rescue`, `AbstractController::Callbacks`,
`StrongParameters`) and omits the browser concerns an RPC endpoint never uses (CSRF,
cookies, flash, view rendering). The handler stays a PORO holding domain logic, so it's
trivially unit-testable.

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
  controller natively — use them for HTTP-level concerns. The library adds no callback
  layer of its own; Rails already provides this.

## Error handling

`ConnectRpc::Error` maps to its Connect code + HTTP status. The controller declares
`rescue_from ConnectRpc::Error` once, so it becomes the wire error body `{code,message,details}`
in exactly one place. An exception that isn't a `ConnectRpc::Error` propagates to the
host's error middleware, per the "let exceptions propagate" policy.

Mapping *arbitrary* exceptions (domain, framework) to Connect codes is the job of an
interceptor, so it applies to every RPC uniformly. A configurable one ships with the
library:

```ruby
connect_service Greet::V1::SERVICE_DESCRIPTOR,
  handler: Greet::V1::GreetHandler.new,
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

## Conformance

The official [connectrpc/conformance](https://github.com/connectrpc/conformance) suite
lives in [`conformance/`](conformance/) and passes **86/86** (Connect + unary) against
the `ActionController::API` transport, with the server-under-test mounted through an
`ActionDispatch` `RouteSet` — including error details, response headers/trailers (on
success *and* error), `connect-timeout-ms` enforcement, and the HTTP-status mapping for
malformed requests (404 unknown method, 405 wrong verb, 415 unsupported media type,
`unimplemented` for unsupported compression). Streaming, gRPC/gRPC-Web, compression, and
TLS remain out of scope. This is the real interop check that hand-written specs can't give.

## Design highlights

- **Reflection-based dispatch, no codegen.** A `protoc`/`buf`-generated service lands in the descriptor pool as a `ServiceDescriptor` whose `MethodDescriptor`s expose input/output message classes. `connect_service` generates the actions purely off that — no per-service generated stubs. (`examples/greet/lib/greet_pb.rb` builds the descriptor in pure Ruby so the example runs with no protoc toolchain.)
- **Rails instrumentation for free.** `process_action.action_controller` fires for every RPC (including errors), carrying `controller`/`action`/`status` plus a `connect_method` payload key (`pkg.Service/Method`) for clean trace/log resource naming.
- **authN vs authZ split.** `AuthInterceptor` (stands in for a real bearer-token verifier) authenticates the `Bearer` token and writes the principal onto the context `values` bag; the handler reads `context[:principal]` for authorization.
- **Connect wire compliance for unary:** `POST /pkg.Service/Method`, `application/json` + `application/proto`, error body `{code,message,details}` with the spec's code→HTTP-status table.

## Layout

```
lib/connect_rpc/
  controller.rb           # the ActionController::API transport (mix-in)
  routing.rb              # route helper: 1 RPC = 1 action
  service_registration.rb # descriptor -> handler binding (reflection)
  codec.rb                # JSON / proto, via google-protobuf
  context.rb  interceptor.rb  exception_mapping_interceptor.rb  errors.rb
examples/greet/           # the example wired up as a real Rails app tree
  app/controllers/greet_controller.rb    # connect_service on ActionController::API
  app/rpc/greet_handler.rb               # domain logic — a plain object (PORO)
  app/rpc/auth_interceptor.rb            # bearer authN interceptor + stub verifier
  config/routes.rb                       # ConnectRpc::Routing.mount(self, ...)
  config/application.rb                  # api_only Rails app boot (Action Controller only)
  proto/greet/v1/greet.proto             # the service contract
  lib/greet_pb.rb                        # hand-built stand-in for `buf generate` output
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
`untyped` — in a typical project their `.rbs` comes from buf's `rbs` plugin.

## Deliberately out of scope

Streaming (enveloped framing), gRPC / gRPC-Web compatibility, request compression,
and the idempotent-GET variant. Unary over the Connect protocol is the whole surface
here; add the rest only when a real consumer needs it.
