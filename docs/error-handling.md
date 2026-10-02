# Error handling

## Raising Connect errors

Raise `ConnectRpcRails::Error` from an action or a callback with a Connect code, an optional message, and optional details:

```ruby
raise ConnectRpcRails::Error.new(:not_found, "no such user")

raise ConnectRpcRails::Error.new(
  :failed_precondition,
  "account is suspended",
  details: [Google::Protobuf::Any.pack(Google::Rpc::ErrorInfo.new(reason: "ACCOUNT_SUSPENDED"))],
)
```

The controller renders it as the Connect error body `{"code": ..., "message": ..., "details": [...]}` with the HTTP status the protocol assigns the code. Trailers set before the raise are still sent.

The codes are the Connect set: `canceled`, `unknown`, `invalid_argument`, `deadline_exceeded`, `not_found`, `already_exists`, `permission_denied`, `resource_exhausted`, `failed_precondition`, `aborted`, `out_of_range`, `unimplemented`, `internal`, `unavailable`, `data_loss`, `unauthenticated`. Any other symbol raises `ArgumentError`.

Exceptions that are neither a `ConnectRpcRails::Error` nor mapped as below propagate to the host's error handling, as they would from any controller.

## Exceptions Rails already classifies

Rails records an HTTP status for known exceptions in `config.action_dispatch.rescue_responses`, which every railtie and many gems register into. Including `ConnectRpcRails::Controller` answers each of those with the Connect code for that status, found through the exception's nearest registered ancestor:

| Exception | Rails status | Connect code |
|---|---|---|
| `ActiveRecord::RecordNotFound` | 404 | `not_found` |
| `ActiveRecord::RecordInvalid` | 422 | `invalid_argument` |
| `ActiveRecord::StaleObjectError` | 409 | `aborted` |
| `ActionController::BadRequest` | 400 | `invalid_argument` |

Add an app-specific classification the Rails way and it gets a code too:

```ruby
# config/application.rb
config.action_dispatch.rescue_responses["MyDomain::Forbidden"] = :forbidden
```

The entries are read when the controller class loads, which in a Rails app is after the initializers have run.

The error message sent is the exception's own message.

## Mapping domain exceptions

For exceptions Rails does not know, or to override the code a registered one gets, use `map_connect_errors`. It applies to every RPC on the controller and its subclasses:

```ruby
class GreetController < ActionController::API
  include ConnectRpcRails::Controller

  connect_service "greet.v1.GreetService"

  map_connect_errors MyDomain::Invalid => :invalid_argument,
    MyDomain::QuotaReached => :resource_exhausted
end
```

Each class gets its own `rescue_from` handler, so nothing is blanket-rescued and unmapped exceptions still propagate. The error message sent is the exception's own message.

Use `map_connect_errors` rather than a hand-written `rescue_from` that raises `ConnectRpcRails::Error`: Rails runs one handler per exception, so an error raised inside a handler escapes the controller instead of being rendered.

## Adding details to every error

Every handler the library installs passes the rescued exception to the controller's private `connect_error_for`, which returns the `ConnectRpcRails::Error` to render. That covers a `ConnectRpcRails::Error` raised by an action or callback, Rails-classified exceptions, `map_connect_errors`, and [validation failures](protovalidate.md). Override it to attach details every error should carry, and call `super` for the code and message:

```ruby
# app/controllers/application_rpc_controller.rb
class ApplicationRpcController < ActionController::API
  include ConnectRpcRails::Controller

  private def connect_error_for(exception)
    error = super
    request_info = Google::Rpc::RequestInfo.new(request_id: request.request_id.to_s)
    ConnectRpcRails::Error.new(error.code, error.message, details: [*error.details, Google::Protobuf::Any.pack(request_info)])
  end
end
```

The argument is the original exception, not the `ConnectRpcRails::Error` built from it, so its class and backtrace are available for a detail such as `google.rpc.DebugInfo`. A validation failure arrives as the error `connect_error_for_violation` built, with the `ViolationError` as its `cause`.

## Exceptions that escape the controller

An exception raised before dispatch, such as a routing error or a failing middleware, never reaches a controller. The host's `config.exceptions_app` would answer it in a shape Connect clients read as a malformed response. Wrap it with `ConnectRpcRails::ExceptionsApp`:

```ruby
# config/application.rb
config.exceptions_app = ConnectRpcRails::ExceptionsApp.new(ActionDispatch::PublicExceptions.new(Rails.public_path))
```

A request carrying `connect-protocol-version`, which Connect clients send on every unary call, is answered with a Connect error. Everything else reaches the wrapped app untouched.

A `ConnectRpcRails::Error` is sent as is. For any other exception, the code comes from the status `rescue_responses` assigns it, so classification stays in one place, and the message is the HTTP status text (`Not Found`), never the exception's message.

To add a detail to every such error, override `connect_error_for` in a subclass:

```ruby
# lib/connect_exceptions_app.rb
require "google/rpc/error_details_pb"

class ConnectExceptionsApp < ConnectRpcRails::ExceptionsApp
  private def connect_error_for(exception, env)
    error = super
    request_info = Google::Rpc::RequestInfo.new(request_id: env["action_dispatch.request_id"].to_s)
    ConnectRpcRails::Error.new(error.code, error.message, details: [*error.details, Google::Protobuf::Any.pack(request_info)])
  end
end
```

With the exceptions app in place, an app does not need a blanket `rescue_from StandardError` to keep speaking the protocol. Let exceptions propagate, and Rails' error logging and the error reporters subscribed to it see them as they see any other.
