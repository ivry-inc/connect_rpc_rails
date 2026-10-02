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
| The decoded request message | `connect_request`, read the way `params` is read |
| Request metadata | `connect_metadata` (request headers, downcased and dasherized), or `request.headers` |
| Leading response metadata | `response.headers` |
| Trailing response metadata | `connect_trailers["x-audit"] = ["1"]` |
| The deadline | `connect_deadline` (a `Time`) and `connect_timeout_ms`, both `nil` without `connect-timeout-ms` |
| State computed for this call | An instance variable |

`connect_trailers` writes Connect's unary wire form (`trailer-`-prefixed headers) for you, on success and on error.

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

The request body is decoded before any callback runs, so a `before_action` can already read `connect_request`. `only:`, `except:`, `skip_before_action`, and inheritance work as usual. Share logic across services with an `ActiveSupport::Concern` or a base controller:

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

The library's transport checks run in a `prepend_before_action`, ahead of every application callback. A request with the wrong verb (405), an unsupported content type (415), an unsupported `content-encoding` (`unimplemented`), or an undecodable body (`invalid_argument`) is answered before authentication sees it.

## Instrumentation

Every RPC, including failed ones, fires `process_action.action_controller` with the usual `controller`, `action`, and `status`, plus a `connect_method` key holding `pkg.Service/Method`. Use it to name traces and log lines:

```ruby
# config/initializers/lograge.rb
Rails.application.configure do
  config.lograge.custom_options = ->(event) { {connect_method: event.payload[:connect_method]} }
end
```

The decoded request is also exposed as `request_parameters`, so the Rails request log and `config.filter_parameters` apply to it.
