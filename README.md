# connect_rpc (prototype)

A minimal [Connect](https://connectrpc.com/docs/protocol/) **unary** RPC server for
Rack/Rails, with a first-class **in-process** transport. Built to validate whether a
Connect-for-Ruby layer is small enough to own, given that `google-protobuf` and
`grpc` are already in the stack and `crossbar-rp` already provides bearer auth.

## The one idea

One handler, two transports, no duplicated logic:

```
wire caller  ──HTTP──▶ RackHandler ──┐
                                      ├─▶ Dispatcher#invoke ─▶ handler (PORO)
host app ────Ruby────▶ InProcess ────┘
```

- `Dispatcher#invoke(service, method, request_message, context)` is the entire core.
- `RackHandler` decodes the Connect request (JSON or binary), runs interceptors, calls the dispatcher, encodes the reply, maps errors to Connect codes.
- `InProcess` hands the dispatcher an already-built message — **no serialization** — seeding the context `values` bag directly.
- Handlers are plain Ruby objects, never controller actions, which is what makes the two transports share one handler.

## Context, values, and callbacks

`Context` carries request `metadata`, the deadline, response headers/trailers, and a
generic **`values`** bag (`context[:key]`) — the same idea as Twirp's env hash or
connect-go's context values. The library never interprets `values`; an
authenticated identity is just a convention (`context[:principal]`) that an auth
interceptor writes and a handler reads. There is deliberately no native "principal".

Handlers can opt into Rails-style per-RPC callbacks (no ActiveSupport dependency):

```ruby
class BillingHandler
  include ConnectRpc::Callbacks
  before_action :authorize!, except: [:health]
  around_action :with_timing
  def ingest_usage(request, context) = ...
  private def authorize!(request, context) = ...  # raise ConnectRpc::Error to reject
end
```

Two composable layers: **interceptors** are global (all services); **callbacks** are
per-handler and scope with `only:`/`except:`.

## Error handling

`Dispatcher#invoke` returns a `Result` — a success message or a failure
`ConnectRpc::Error` — and is the **only** place a `ConnectRpc::Error` is caught.
The transports just render it: the wire transport encodes an error frame, the
in-process transport re-raises for the caller. Neither transport has an error
rescue of its own.

Mapping *arbitrary* exceptions (domain, framework) to Connect codes is the job of
an interceptor, so it applies to both transports at once. A configurable one ships
with the library:

```ruby
Dispatcher.new(interceptors: [
  ExceptionMappingInterceptor.new(
    ActiveRecord::RecordNotFound => :not_found,
    MyDomain::Invalid           => :invalid_argument,
  ),
  # ...your other interceptors
])
```

It rescues only the configured classes (never a blanket rescue); anything unmapped
propagates to the host's error middleware, per the "let exceptions propagate"
policy.

## Conformance

The official [connectrpc/conformance](https://github.com/connectrpc/conformance)
suite runs against the library (see [`conformance/`](conformance/)). Scoped to
Connect + unary, it passes **86/86** — including error details, response
headers/trailers, `connect-timeout-ms` enforcement, and the HTTP-status mapping
for malformed requests. Streaming, gRPC/gRPC-Web, compression, and TLS are out of
scope. This is the real interop check that hand-written specs can't give.

## What the prototype proves

- **Reflection-based dispatch, no codegen.** A `protoc`/`buf`-generated service lands in the descriptor pool as a `ServiceDescriptor` whose `MethodDescriptor`s expose input/output message classes. `ServiceRegistration` routes purely off that — no per-service generated stubs. (`examples/billing/billing_pb.rb` builds the descriptor in pure Ruby so the demo runs with no protoc toolchain.)
- **authN vs authZ split.** `AuthInterceptor` (stands in for `crossbar-rp` bearer verification) runs for every transport but only authenticates when `context[:principal]` is absent. A trusted in-process caller seeds `values: {principal: …}` and skips the token check; a wire caller is authenticated from its `Bearer` token. Authorization (realm/payer scoping) stays in the handler, reading `context[:principal]`.
- **Connect wire compliance for unary:** `POST /pkg.Service/Method`, `application/json` + `application/proto`, error body `{code,message,details}` with the spec's code→HTTP-status table.

## Layout

```
lib/connect_rpc/
  dispatcher.rb           # the transport-agnostic core
  rack_handler.rb         # HTTP (Connect unary) transport
  in_process.rb           # in-process transport
  service_registration.rb # descriptor -> handler binding (reflection)
  codec.rb                # JSON / proto, via google-protobuf
  context.rb  interceptor.rb  errors.rb
examples/billing/         # example service, handler, auth interceptor
spec/                     # RSpec: in-process + wire, auth, error mapping
```

## Run

```sh
rspec          # specs (in-process + wire, auth, error mapping)
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
