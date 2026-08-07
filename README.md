# connect_rpc_rails

A minimal [Connect](https://connectrpc.com/docs/protocol/) **unary** RPC server for
Rails, built on `ActionController::API`. It gives you a Connect-for-Ruby layer that is
small enough to own outright: a service is an ordinary Rails controller, so it reuses
`google-protobuf` and the observability you already have rather than shipping a parallel
stack.

## How it works

A Connect service is an `ActionController::API` controller: each RPC in the descriptor
is **one Rails action on that controller**, so every call flows through the normal
controller lifecycle. Because `process_action.action_controller` fires, the entire
Rails observability ecosystem (Datadog resource naming, Sentry transactions, lograge,
the `Completed 200 in Xms` request log) works with no extra wiring. The RPC method
holds the domain logic; the library wraps it with the transport.

```
caller ──HTTP──▶ Rails router ──▶ GreetController#say_hello
                                  (ConnectRpcRails::Controller: decode ▸ callbacks ▸ encode)
```

```ruby
# app/controllers/greet_controller.rb
class GreetController < ActionController::API
  include ConnectRpcRails::Controller
  include BearerAuthentication          # a concern with a before_action

  connect_service "greet.v1.GreetService"   # the name the .proto gives it

  # An ordinary action — no arguments, like any other Rails action. The library decodes
  # the request message (`connect_request`, read the way you read `params`) and encodes
  # whatever message you return. `principal` was set by the before_action; authZ lives
  # here.
  def say_hello
    Greet::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
  end
end
```

```ruby
# config/routes.rb — 1 RPC = 1 route.
Rails.application.routes.draw do
  connect_service "greet.v1.GreetService" => :greet
end
```

**The RPC runs on a per-request instance.** That is the reason there is no handler
object to register: an object held on the controller class would be shared by every
request in the process, so anything one call left in an instance variable would be
readable by the next caller — the mismatch that bites when gRPC-style handlers (one
long-lived instance) are mixed into Rails (one instance per request). Here the RPC
method *is* an action, so Rails' per-request instance is the only lifecycle in play.
Domain logic that shouldn't live in a controller belongs in an ordinary object the
action calls, constructed inside the action like anywhere else in Rails.

**Routes come from the descriptor, per service.** The routes file names the service the
way the `.proto` does and points it at a controller as a string, exactly like any other
Rails route — so drawing the routes doesn't load the controller class, and both ends of the
mapping grep straight to the protobuf definition. Every method the descriptor declares
becomes one route to the action implementing it; the method list lives in the `.proto` and
nowhere else. What the controller actually serves is then its own business: a declared RPC
with no action is answered Connect `unimplemented` (HTTP 501, not a 404, as the protocol
wants) through Rails' own `action_missing`, and the single catch-all the DSL draws over the
service prefix makes a method the descriptor never declared a plain 404.

Under eager loading — production, and CI — the DSL also resolves each routed controller as
the routes are drawn and checks that it serves the service it was wired to, so a
mis-wired route raises at boot instead of 404-ing in production. Rails eager loads before it
draws the routes, so that costs no autoloading; with lazy loading (development) the class is
left untouched.

**Why `ActionController::API`, not a bare Rack transport?** A bespoke Rack transport
would mean going off the controller path and losing everything that hangs off
`process_action.action_controller` (Datadog/Sentry/lograge/the request log), then
rebuilding each integration by hand. `ActionController::API` ships exactly the useful
modules (`Instrumentation`, `Logging`, `Rescue`, `AbstractController::Callbacks`,
`StrongParameters`) and omits the browser concerns an RPC endpoint never uses (CSRF,
cookies, flash, view rendering). It also brings the per-request instance lifecycle,
which is what keeps request state from outliving the request.

## Reading the call, and cross-cutting logic

A Connect call *is* an HTTP request, so there is no per-call context object to learn:

| what you want | where it is |
|---|---|
| the decoded request message | `connect_request` — read it the way you read `params` |
| request metadata | `connect_metadata` (the request's headers, downcased and dasherized), or `request.headers` |
| leading response metadata | `response.headers` |
| trailing response metadata | `connect_trailers["x-audit"] = ["1"]` — the helper writes Connect's unary `trailer-` form |
| the deadline | `connect_deadline` / `connect_timeout_ms`, for budgeting your own downstream calls |
| anything you computed for this call | an instance variable, as in any controller |

**Cross-cutting logic is Rails callbacks, and only that.** There is no interceptor layer:
`before_action` for auth, `around_action` to wrap a call, `rescue_from` for exception
mapping. The body is decoded *before* the callbacks run, so a `before_action` can already
read `connect_request` — which is what makes callbacks a complete replacement rather than a
partial one. Reuse across services is an `ActiveSupport::Concern` (see
[`BearerAuthentication`](examples/greet/app/controllers/concerns/bearer_authentication.rb))
or a shared base controller, and on top of that you get `only:` / `except:`, inheritance
and `skip_before_action`, none of which an interceptor chain offers.

Callbacks halt the Rails way: `render` a response, or raise a `ConnectRpcRails::Error` and
let the library's `rescue_from` render the wire error.

The library's own transport checks (POST-only, media type, undecodable body) run in a
`prepend_before_action`, so a wrong-verb or unreadable request is answered as the protocol
requires before any application callback — auth never sees a request that should be a 405.

## Error handling

`ConnectRpcRails::Error` maps to its Connect code + HTTP status. The controller declares
`rescue_from ConnectRpcRails::Error` once, so it becomes the wire error body `{code,message,details}`
in exactly one place. An exception that isn't a `ConnectRpcRails::Error` propagates to the
host's error middleware, per the "let exceptions propagate" policy.

**Exceptions Rails already classifies need no mapping.** Rails keeps that classification in
`config.action_dispatch.rescue_responses` — the registry every railtie and gem writes into,
where `ActiveRecord::RecordNotFound` is `:not_found` and `ActiveRecord::RecordInvalid` is
`:unprocessable_content` — so including the module installs a Connect code for each of its
entries, read off the nearest classified ancestor. A `RecordNotFound` out of an RPC is a
Connect `not_found` without the app restating it.

Mapping the *rest* — your own domain exceptions — is `map_connect_errors`, which applies to
every RPC on the controller and overrides the code an entry above would have got:

```ruby
map_connect_errors MyDomain::Invalid => :invalid_argument,
  MyDomain::QuotaReached => :resource_exhausted
```

That is `rescue_from` with the conversion filled in: each class gets its own handler, so
nothing is blanket-rescued and anything unmapped still propagates. It exists as a macro
because a hand-written `rescue_from` can't simply `raise` a `ConnectRpcRails::Error` —
Rails calls one handler per exception, so the raise would escape instead of reaching the
handler that renders the wire error.

## Conformance

The official [connectrpc/conformance](https://github.com/connectrpc/conformance) suite
lives in [`conformance/`](conformance/) and passes **86/86** (Connect + unary) against
the `ActionController::API` transport, with the server-under-test mounted through an
`ActionDispatch` `RouteSet` — including error details, response headers/trailers (on
success *and* error), `connect-timeout-ms` enforcement, and the HTTP-status mapping for
malformed requests (404 unknown method, 405 wrong verb, 415 unsupported media type,
`unimplemented` for an unimplemented method and for unsupported compression). Streaming, gRPC/gRPC-Web, compression, and
TLS remain out of scope. This is the real interop check that hand-written specs can't give.

## Design highlights

- **Reflection-based dispatch, no codegen.** A `protoc`/`buf`-generated service lands in the descriptor pool as a `ServiceDescriptor` whose `MethodDescriptor`s expose input/output message classes. `connect_service` takes the service's full name, looks it up in the pool, and derives the action names and message types purely off that — no per-service generated stubs. (`examples/greet/lib/greet_pb.rb` builds the descriptor in pure Ruby so the example runs with no protoc toolchain.)
- **Rails instrumentation for free.** `process_action.action_controller` fires for every RPC (including errors), carrying `controller`/`action`/`status` plus a `connect_method` payload key (`pkg.Service/Method`) for clean trace/log resource naming.
- **No object outlives the request.** The RPC is a controller action, so there is no handler singleton on the class to accumulate state between callers — the failure mode of putting gRPC-style handlers behind Rails.
- **Nothing to learn beyond Rails.** An RPC is an action, cross-cutting logic is a callback, exception mapping is `rescue_from`, metadata is headers. The only Connect-specific thing in a controller is `connect_request`.
- **authN vs authZ split.** `BearerAuthentication` (a concern standing in for a real bearer-token verifier) authenticates the `Bearer` token in a `before_action` and exposes `principal`; the RPC method authorizes against it.
- **Connect wire compliance for unary:** `POST /pkg.Service/Method`, `application/json` + `application/proto`, error body `{code,message,details}` with the spec's code→HTTP-status table.

## Layout

```
lib/connect_rpc_rails/
  controller.rb           # the ActionController::API transport (mix-in)
  routing.rb              # routes DSL: a route per declared RPC + the unknown-method catch-all
  railtie.rb              # installs the routes DSL / Connect's content-type at Rails boot
  service_registration.rb # descriptor -> RPC table (reflection)
  codec.rb                # JSON / proto, via google-protobuf
  errors.rb               # Connect codes -> HTTP status, wire error body
examples/greet/           # the example as a real, bootable Rails app (own Gemfile + config.ru)
  app/controllers/greet_controller.rb    # connect_service + the RPC action
  app/controllers/concerns/bearer_authentication.rb  # authN as a before_action + stub verifier
  config/routes.rb                       # connect_service "greet.v1.GreetService" => :greet
  config/application.rb                  # api_only Rails app boot (Action Controller + Active Record)
  proto/greet/v1/greet.proto             # the service contract
  lib/greet_pb.rb                        # hand-built stand-in for `buf generate` output
spec/                     # RSpec: controller, routing, auth, error mapping, instance lifecycle
```

## Run

Ruby is pinned in `.mise.toml`, so [mise](https://mise.jdx.dev) users get the right
interpreter automatically; otherwise use Ruby 3.4.

```sh
rspec          # specs (controller, routing, auth, error mapping, deadline)
rubocop        # Shopify ruleset
rake rbs       # regenerate + validate sig/generated from inline annotations
rake steep     # regenerate, then type check lib with Steep
```

### The example service

`examples/greet` is a bootable Rails app with its own bundle (the gem itself depends only
on actionpack, so full Rails lives in the example's `Gemfile`, not the gem's):

```sh
cd examples/greet
bundle install
bundle exec puma -b tcp://127.0.0.1:9711 config.ru

curl -X POST -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer valid-token' \
  -d '{"name":"Ada","preferredLanguage":"ja"}' \
  http://127.0.0.1:9711/greet.v1.GreetService/SayHello
# => {"greeting":"こんにちは, Ada!"}
```

Drop the token for `401 unauthenticated`, send `{}` for `400 invalid_argument`, use `GET`
for `405`, and ask for a method the service doesn't declare for a `404`.

## Types

The library carries [rbs-inline](https://github.com/soutaro/rbs-inline) annotations
(`# rbs_inline: enabled`, `#:` method signatures). `rake rbs` transpiles them into
`sig/generated/**/*.rbs` and runs `rbs validate`. Protobuf messages are typed
`untyped` — in a typical project their `.rbs` comes from buf's `rbs` plugin.

`rake steep` goes further and checks `lib` against those signatures. Dependency
signatures come from [gem_rbs_collection](https://github.com/ruby/gem_rbs_collection);
run `rbs collection install` once to populate `.gem_rbs_collection` from
`rbs_collection.lock.yaml`. Note the collection's `actionpack` and `google-protobuf`
signatures lag the versions this gem builds against, and much of that surface is
`untyped` there, so Steep checks this library's own logic rather than its use of Rails.

`ConnectRpcRails::Controller` is a mix-in, so `sig/manual/controller_self.rbs` declares
what it is mixed into (`ActionController::API`) plus the class-level accessors
`extend ClassMethods` installs — a shape RBS cannot infer from the module body.

## Deliberately out of scope

Streaming (enveloped framing), gRPC / gRPC-Web compatibility, request compression,
and the idempotent-GET variant. Unary over the Connect protocol is the whole surface
here; add the rest only when a real consumer needs it.
