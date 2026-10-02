# connect_rpc_rails: Connect unary RPCs as ordinary Rails controller actions

connect_rpc_rails serves [Connect](https://connectrpc.com/docs/protocol/) unary RPCs from a Rails app. A service is an `ActionController::API` controller and each RPC is one of its actions, so callbacks, `rescue_from`, and the `process_action.action_controller` instrumentation that Datadog, Sentry, lograge, and the Rails request log hook into all apply with no extra wiring.

Services are read off the `google-protobuf` descriptor pool, so the only generated code is the message classes `buf`/`protoc` already emit. The library is small enough to own outright: it is a Connect transport for Rails, not a parallel framework.

## Features

- One RPC is one controller action, routed per service from the `.proto` descriptor
- Cross-cutting logic is Rails callbacks (`before_action`, `around_action`, `rescue_from`), with no interceptor layer to learn
- Exceptions Rails already classifies become Connect codes without mapping: `ActiveRecord::RecordNotFound` is `not_found`
- Connect-shaped errors even for exceptions that escape before dispatch, through `ConnectRpcRails::ExceptionsApp`
- `connect-timeout-ms` deadlines, request metadata, and response trailers
- Optional request validation against [`buf.validate`](https://buf.build/docs/protovalidate/) rules through [protovalidate](https://github.com/sorah/protovalidate-rb)
- Passes every in-scope case of the official [Connect conformance suite](conformance/)
- RBS signatures included

## Requirements

- Ruby 3.4 or later
- Rails (Action Pack) 7.0 or later
- google-protobuf 4.26 or later, below 5

## Installation

```
bundle add connect_rpc_rails
```

## Usage

Given a service contract:

```protobuf
// proto/greet/v1/greet.proto
syntax = "proto3";
package greet.v1;

service GreetService {
  rpc SayHello(SayHelloRequest) returns (SayHelloResponse);
}

message SayHelloRequest {
  string name = 1;
}

message SayHelloResponse {
  string greeting = 1;
}
```

### 1. Load the generated messages

Generate Ruby code with `buf generate` or `protoc --ruby_out`, and require it before the routes are drawn. `connect_service` looks the service up in the descriptor pool by name.

```ruby
# config/application.rb
require_relative "../lib/greet/v1/greet_pb"
```

### 2. Implement the service as a controller

```ruby
# app/controllers/greet_controller.rb
class GreetController < ActionController::API
  include ConnectRpcRails::Controller

  connect_service "greet.v1.GreetService"

  def say_hello
    Greet::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
  end
end
```

An RPC takes no arguments, like any other action. `connect_request` is the decoded request message, and the returned message is encoded in the caller's format (`application/json` or `application/proto`).

### 3. Route it

```ruby
# config/routes.rb
Rails.application.routes.draw do
  connect_service "greet.v1.GreetService" => :greet
end
```

This draws `POST /greet.v1.GreetService/SayHello` to `GreetController#say_hello`, one route per RPC the descriptor declares.

### 4. Call it

```console
$ curl -X POST -H 'Content-Type: application/json' \
    -d '{"name":"Ada"}' \
    http://localhost:3000/greet.v1.GreetService/SayHello
{"greeting":"Hello, Ada!"}
```

Raise `ConnectRpcRails::Error.new(:invalid_argument, "name is required")` to answer an error, and use `before_action` for authentication as in any controller. [`examples/greet`](examples/greet/) is a bootable app with a bearer-token concern and error handling; see [docs/development.md](docs/development.md#the-example-service) to run it.

## Documentation

- [Writing services](docs/controllers.md): reading the request, metadata, trailers, deadlines, callbacks
- [Routing](docs/routing.md): one controller per service or per RPC, and what unrouted calls are answered
- [Error handling](docs/error-handling.md): Connect codes, Rails' exception classification, `map_connect_errors`, `ExceptionsApp`
- [Validating requests with protovalidate](docs/protovalidate.md)
- [Development](docs/development.md): running the specs, type checks, the conformance suite, and releasing
- [Design](DESIGN.md): how the transport hooks into `ActionController::API`, and why

## Caveats

- Only the Connect protocol's unary RPCs are served. Streaming, gRPC and gRPC-Web, request compression, and the idempotent GET variant are out of scope.
- `connect-timeout-ms` is enforced with `Timeout.timeout`, which interrupts the action wherever it is running when the deadline passes.
- The message of an exception mapped to a Connect code, including Rails-classified ones such as `ActiveRecord::RecordNotFound`, is sent to the caller as the error message.

## Development

```
bundle install
bundle exec rspec
```

See [docs/development.md](docs/development.md) for the full set of checks.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ivry-inc/connect_rpc_rails.

## License

This project is licensed under the Apache-2.0 License.

Copyright 2026 IVRy Inc.
