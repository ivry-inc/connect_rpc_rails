# Design

connect_rpc_rails is a Connect unary transport that runs inside the Rails controller lifecycle instead of beside it. This document covers how that works and why. For usage, see the [README](README.md) and the guides in [docs/](docs/).

## One RPC is one action

A Connect service is an `ActionController::API` controller, and each RPC in the service's descriptor is one action on it. Every call goes through the normal controller path:

```
caller ──HTTP──▶ Rails router ──▶ GreetController#say_hello
                                  (ConnectRpcRails::Controller: decode ▸ callbacks ▸ encode)
```

The transport wraps the action rather than generating it. The RPC method holds the domain logic, and the library adds decoding, encoding, deadlines, and error rendering around it.

Because `process_action.action_controller` fires for every call, including failed ones, the Rails observability ecosystem works unchanged: Datadog resource naming, Sentry transactions, lograge, and the `Completed 200 in Xms` request log. The payload gains a `connect_method` key (`pkg.Service/Method`) through `append_info_to_payload`, the hook lograge and Datadog use for custom fields.

## Why `ActionController::API`, not a bare Rack transport

A bespoke Rack transport would leave the controller path and lose everything attached to `process_action.action_controller`, then rebuild each integration by hand. `ActionController::API` ships the modules an RPC endpoint needs (`Instrumentation`, `Logging`, `Rescue`, `AbstractController::Callbacks`, `StrongParameters`) and omits the browser concerns it never uses (CSRF, cookies, flash, view rendering). It also brings the per-request instance lifecycle described next.

## No object outlives the request

The RPC runs on the controller instance Rails builds for each request, so there is no handler object to register. A handler held on the controller class would be one instance shared by every request in the process, and anything one call left in an instance variable would be readable by the next caller. That mismatch is what bites when gRPC-style handlers, one long-lived instance, are placed behind Rails, one instance per request. Here the RPC method is an action, so Rails' lifecycle is the only one in play.

## Reflection-based dispatch

`protoc`/`buf`-generated code registers a `ServiceDescriptor` in the descriptor pool, and its `MethodDescriptor`s expose the input and output message classes. `connect_service` looks the service up by its full name and derives the action names and message types from the descriptor alone (`ServiceRegistration`). No per-service stubs are generated, and the service name in Ruby greps straight to the `.proto`.

## Routes come from the descriptor

The routes DSL (`ConnectRpcRails::Routing`) draws one route per RPC the descriptor declares, so the method list lives in the `.proto` and nowhere else. Controllers are named as strings, as with `to:`, so drawing the routes does not load controller classes.

What a controller actually serves is its own business:

- A declared RPC with no action is answered `unimplemented` (HTTP 501, as the protocol requires, not a 404). This goes through Rails' own `action_missing` hook.
- One catch-all over the service prefix, drawn after the RPC routes, makes a method the descriptor never declares a plain 404. It renders rather than raising a `RoutingError`, so it does not depend on the host's exception middleware.
- Routes match every verb (`via: :all`), so a wrong verb reaches the controller and becomes a Connect-correct 405 rather than a router 404. `format: false` keeps the dots in a service name from being parsed as a format suffix.

In the per-RPC form, every mapped name must be declared by the descriptor, so a typo or rename fails at boot. An RPC left out is routed to the first mapped controller, which answers it `unimplemented`, the same as a declared RPC nobody implements.

Under eager loading, the DSL resolves each routed controller as the routes are drawn and checks it serves the service it was wired to, so a mis-wired route raises at boot instead of 404-ing in production. Rails eager loads before drawing routes, so the check autoloads nothing. With lazy loading the class is left untouched.

## Request lifecycle

- `process_action` decodes the body once, before callbacks and instrumentation. The typed message becomes `connect_request`, and its hash form populates `request_parameters`, so the request log and `config.filter_parameters` see the request without Rails parsing a JSON body a second time. The wire format is reported through the formats header rather than `request.format=`, which would inject a `:format` key into params.
- A malformed body is deferred rather than raised during decode, so it flows through instrumentation and the normal error path and is logged like any other request.
- Transport preconditions (POST only, supported media type, no request compression, decodable body) run in a `prepend_before_action`, ahead of every application callback. Authentication never sees a request that should be a 405.
- `connect-timeout-ms` is enforced by an `around_action`, so the callbacks and the RPC together run under the deadline.
- The action is invoked through `send_action`, Rails' documented seam for changing how action methods are called, and its return value is encoded in the request's codec.

## Callbacks instead of interceptors

A Connect call is an HTTP request, so cross-cutting logic is Rails callbacks and nothing else: `before_action` for auth, `around_action` to wrap a call, `rescue_from` for exception mapping. Decoding before the callbacks is what makes this a complete replacement for interceptors: a `before_action` can already read `connect_request`. Callbacks also bring `only:`, `except:`, inheritance, and `skip_before_action`, which an interceptor chain does not.

There is no context object either. Metadata is headers, trailers are a hash the transport prefixes into `trailer-` headers, and per-call state is an instance variable.

## Error mapping

`ConnectRpcRails::Error` maps to its Connect code and HTTP status, and a single `rescue_from` renders it as the wire body `{code,message,details}`. Anything else propagates to the host's error handling.

Rails keeps its exception taxonomy in `config.action_dispatch.rescue_responses`, the registry every railtie and gem writes into. Including the controller module registers a `rescue_from` per entry, by class name so no class is loaded, and the status is read back as a Connect code. The status is taken from the nearest registered ancestor, since `rescue_from` matches subclasses that are not keys themselves. That reverse table (`Error::HTTP_STATUS_TO_CODE`) is the inverse of Connect's code-to-status table, not gRPC's HTTP-to-status mapping, which describes a client reading a response with no RPC status at all. The reasoning is recorded at the table in [`errors.rb`](lib/connect_rpc_rails/errors.rb).

`map_connect_errors` is `rescue_from` with the conversion filled in: one registration per class, so nothing is blanket-rescued. It exists as a macro because Rails calls one handler per exception, so a hand-written handler that raises a `ConnectRpcRails::Error` would escape instead of reaching the handler that renders it.

Every `rescue_from` the library registers points at one handler, which renders `connect_error_for(exception)`. An app overrides that one method to attach details every error should carry, and still sees the exception that was rescued rather than the `ConnectRpcRails::Error` built from it. It mirrors `ExceptionsApp#connect_error_for`, the hook for errors that escape the controller.

`ConnectRpcRails::ExceptionsApp` covers what escapes before dispatch. It recognizes Connect requests by `connect-protocol-version`, which the protocol requires on every unary call, and reads the status the way `ActionDispatch::PublicExceptions` does, so `rescue_responses` remains the one place an app classifies exceptions. It sends the status text rather than the exception message, which can quote internals.

## Request validation

`ConnectRpcRails::MessageValidatable` is loaded only by `require "connect_rpc_rails/protovalidate"`, so protovalidate stays out of the gem's dependencies.

The validation is a `before_action` registered at include time, so `skip_before_action` has an entry to delete. Each RPC definition re-registers it through `method_added`, which moves it to the end of the chain, behind authentication declared above. Answering an invalid body before an unauthenticated one would tell any caller what a valid body looks like.

`google.rpc.BadRequest` is looked up in the descriptor pool rather than required, because googleapis belongs to the application: it may generate `error_details.proto` itself or bundle `googleapis-common-protos-types`.

## Conformance

The official [connectrpc/conformance](https://github.com/connectrpc/conformance) suite lives in [`conformance/`](conformance/) and passes all 84 in-scope cases (Connect protocol, unary) with the server-under-test mounted through an `ActionDispatch` `RouteSet`. That covers error details, response headers and trailers on success and error, `connect-timeout-ms` enforcement, and the HTTP status mapping for malformed requests (404 unknown method, 405 wrong verb, 415 unsupported media type, `unimplemented` for unimplemented methods and unsupported compression). It is the interop check hand-written specs cannot give.

## Scope

Streaming (enveloped framing), gRPC and gRPC-Web compatibility, request compression, and the idempotent GET variant are out of scope. Unary over the Connect protocol is the whole surface, and the rest is added only when a real consumer needs it.

## Source layout

```
lib/connect_rpc_rails/
  controller.rb           # the ActionController::API transport (mix-in)
  routing.rb              # routes DSL: a route per declared RPC and the unknown-method catch-all
  railtie.rb              # installs the routes DSL and Connect's content type at Rails boot
  service_registration.rb # descriptor to RPC table (reflection)
  codec.rb                # JSON and proto, via google-protobuf
  errors.rb               # Connect codes to HTTP status, wire error body
  exceptions_app.rb       # config.exceptions_app wrapper for what escapes the controller
  message_validatable.rb  # optional buf.validate checks (require "connect_rpc_rails/protovalidate")
examples/greet/           # a bootable Rails app using the library
conformance/              # the Connect conformance suite's server-under-test
spec/                     # RSpec: controller, routing, error mapping, instance lifecycle, validation
```
