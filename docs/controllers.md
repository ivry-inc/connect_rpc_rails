# Writing services

A Connect service is an `ActionController::API` controller that includes `ConnectRpcRails::Controller` and names the service it serves:

```ruby
# app/controllers/greet_controller.rb
class GreetController < ActionController::API
  include ConnectRpcRails::Controller
  include BearerAuthentication

  connect_service "greet.v1.GreetService"

  def say_hello
    Greet::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
  end
end
```

`connect_service` takes the service's full name as the `.proto` spells it. Each RPC is the action named after the method in snake case (`SayHello` is `say_hello`). An action takes no arguments and returns the response message.

The controller is built per request, as for any Rails action, so instance variables never leak between callers. Domain logic that does not belong in a controller goes in an ordinary object the action constructs and calls.

## Reading the call

A Connect call is an HTTP request, so there is no separate context object:

| What | Where |
|---|---|
| The decoded request message | `connect_request` (or its shorthand `message`), read the way `params` is read |
| Request metadata | `connect_metadata` (request headers, downcased and dasherized), or `request.headers` |
| Leading response metadata | `response.headers` |
| Trailing response metadata | `connect_trailers["x-audit"] = ["1"]` |
| The deadline | `connect_deadline` (a `Time`) and `connect_timeout_ms`, both `nil` without `connect-timeout-ms` |
| State computed for this call | An instance variable |

`connect_trailers` writes Connect's unary wire form (`trailer-`-prefixed headers) for you, on success and on error.

### Sorbet

With [tapioca](https://github.com/Shopify/tapioca) in the bundle, `tapioca dsl` picks up a compiler shipped in this gem that types `connect_request` and `message` on every controller declaring `connect_service`: as the request class when all of the service's RPCs take the same one, and as their union otherwise, which an action narrows itself.

```rbi
class GreetController
  private

  sig { returns(::Greet::V1::SayHelloRequest) }
  def connect_request; end

  sig { returns(::Greet::V1::SayHelloRequest) }
  def message; end
end
```

## Deadlines

When the caller sends `connect-timeout-ms`, the whole action, callbacks included, runs under that deadline. Exceeding it answers `deadline_exceeded`. A malformed header value is answered `invalid_argument`.

Read `connect_deadline` to budget downstream calls:

```ruby
def say_hello
  timeout = connect_deadline ? connect_deadline - Time.now : 5
  greeting = GreetingService.fetch(connect_request.name, timeout:)
  Greet::V1::SayHelloResponse.new(greeting:)
end
```

The deadline is enforced with `Timeout.timeout`, so an action past its deadline is interrupted wherever it is.

## Cross-cutting logic

Callbacks are the only extension point. Use `before_action` for authentication, `around_action` to wrap a call, and `rescue_from` or [`map_connect_errors`](error-handling.md#mapping-domain-exceptions) for exception mapping.

The request message is decoded before any callback runs, so a `before_action` can already read `connect_request`. `only:`, `except:`, `skip_before_action`, and inheritance work as usual. Share logic across services with an `ActiveSupport::Concern` or a base controller:

```ruby
# app/controllers/concerns/bearer_authentication.rb
module BearerAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_bearer_token
  end

  private def authenticate_bearer_token
    token = request.authorization.to_s.delete_prefix("Bearer ")
    @principal = Principal.verify(token)
    raise ConnectRpcRails::Error.new(:unauthenticated, "invalid bearer token") unless @principal
  end

  private attr_reader :principal
end
```

A callback halts the Rails way: `render` a response, or raise a `ConnectRpcRails::Error` and let the library render the wire error.

The library's transport checks run in a `prepend_before_action`, ahead of every application callback. A request with the wrong verb (405), an unsupported content type or GET `encoding` (415), unsupported compression (`unimplemented`), or an undecodable message (`invalid_argument`) is answered before authentication sees it.

## Serving GET

A unary RPC the `.proto` declares free of side effects can be called with GET as well as POST:

```protobuf
service GreetService {
  rpc SayHello(SayHelloRequest) returns (SayHelloResponse) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}
```

A GET carries the request in its query string, so the URL alone identifies the call:

```
GET /greet.v1.GreetService/SayHello?connect=v1&encoding=json&message=%7B%22name%22%3A%22Ada%22%7D
```

Clients send GET only when asked to: connect-es with `useHttpGet: true` on `createConnectTransport`, connect-go with the `WithHTTPGet` client option. Both use POST for an RPC without the option.

Nothing changes in the controller. A GET reaches the same action, `connect_request` is decoded from the `message` parameter before the callbacks run, and the response is encoded in the codec the `encoding` parameter names. `params` holds the decoded message and any query parameters other than Connect's own, unless Rails cannot parse the query (a binary message sent without `base64=1`, or any parameter that is not valid UTF-8). In that case it holds only the decoded message.

The library sets no cache headers. Set them in the action as in any controller:

```ruby
def say_hello
  expires_in 5.minutes
  Greet::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
end
```

`expires_in` alone marks the response `private`, so only the caller's own browser keeps it. `public: true` or `s-maxage` lets a shared cache such as a CDN serve one caller's response to every request for that URL, whatever its `Authorization` header and without running the controller's authentication. Use them only on an RPC whose response does not depend on who is calling.

Only `NO_SIDE_EFFECTS` opens GET. `IDEMPOTENT`, or no option at all, keeps the RPC POST-only, and a GET to it is answered 405, as is a GET to a streaming RPC whatever its option. The option is a promise the action has to keep: a GET needs no CORS preflight and can be sent by a link or an `<img>` tag on any site, so an RPC that changes state must not carry it.

A GET's request travels in its URL, where `config.filter_parameters` cannot mask the message's fields: Rails filters a query value by its key alone. The raw message reaches Rails' `Started GET` log line, the `path` of the controller instrumentation payloads, proxy, load balancer and CDN access logs, and browser history. `config.filter_parameters += [/\Amessage\z/]` masks it in Rails' own output, and also masks any request field named `message`. An RPC whose request carries credentials or personal data should not be declared `NO_SIDE_EFFECTS`.

## Instrumentation

Every RPC, including failed ones, fires `process_action.action_controller` with the usual `controller`, `action`, and `status`, plus a `connect_method` key holding `pkg.Service/Method`. Use it to name traces and log lines:

```ruby
# config/initializers/lograge.rb
Rails.application.configure do
  config.lograge.custom_options = ->(event) { {connect_method: event.payload[:connect_method]} }
end
```

The decoded request is also exposed as `request_parameters`, so it appears in `payload[:params]` and the request log's `Parameters:` line, filtered by `config.filter_parameters`. A GET's URL is not filtered by field (see [Serving GET](#serving-get)). The `format` is the request's codec, `:json` or `:proto`, whether it came from the content type or a GET's `encoding`.
