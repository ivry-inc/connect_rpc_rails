# Validating requests with protovalidate

A request message whose `.proto` carries [`buf.validate`](https://buf.build/docs/protovalidate/) rules can be checked before the RPC runs, using [protovalidate](https://github.com/sorah/protovalidate-rb). protovalidate is not a dependency of connect_rpc_rails, so the integration is loaded with its own `require`.

## Setup

```ruby
# Gemfile
gem "protovalidate", ">= 0.1.0.beta3"
gem "googleapis-common-protos-types"
```

`google.rpc.BadRequest`, which violations are answered with, is looked up in the descriptor pool rather than required. Bundle `googleapis-common-protos-types` and require `google/rpc/error_details_pb`, or generate `google/rpc/error_details.proto` alongside your own protos.

Then include `ConnectRpcRails::MessageValidatable`:

```ruby
# app/controllers/greet_controller.rb
require "connect_rpc_rails/protovalidate"

class GreetController < ActionController::API
  include ConnectRpcRails::Controller
  include ConnectRpcRails::MessageValidatable
  include BearerAuthentication

  connect_service "greet.v1.GreetService"

  def say_hello
    Greet::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
  end
end
```

Register your messages' rules at boot, as the protovalidate README describes, so no request pays for compiling them.

## What a violation is answered

A violation is answered as [AIP-193](https://google.aip.dev/193) describes: `invalid_argument`, with a `google.rpc.BadRequest` carrying one `FieldViolation` per violated rule.

```json
{"code": "invalid_argument", "message": "preferredLanguage: must be at least 2 characters",
 "details": [{"type": "google.rpc.BadRequest", "value": "..."}]}
```

- Fields are named in the caller's encoding: `preferredLanguage` for a JSON body, `preferred_language` for a binary one. Nested paths are spelled the same way, such as `parts[1].partName` and `labels["primary"].partName`.
- The reason is the rule id upper-snake-cased (`string.min_len` becomes `STRING_MIN_LEN`), or `INVALID_VALUE` for an id that cannot be an AIP-193 reason.
- The check runs after the controller's authentication. It is a `before_action` that moves behind the callbacks declared above each RPC definition, so an unauthenticated caller is answered `unauthenticated` without its body being judged, and learns nothing about what a valid body looks like.

## Answering differently

A violation raises `ConnectRpcRails::MessageValidatable::ViolationError`, carrying `violations` and `request_message`. Override `connect_error_for_violation` to build a different `ConnectRpcRails::Error` from it:

```ruby
private def connect_error_for_violation(error)
  ConnectRpcRails::Error.new(:failed_precondition, error.message)
end
```

The rendered error is raised with the `ViolationError` as its `cause`, so an error reporter walking the chain reaches the validation.

## Opting out

Skip the check for a controller, such as a subclass of a base controller that includes `MessageValidatable`, with `skip_before_action` at its top:

```ruby
class GreetSayHelloController < GreetBaseController
  skip_before_action :validate_connect_message!

  def say_hello = ...
end
```
