# Routing

`connect_service` in the routes file draws one route per RPC the service's descriptor declares. The controller is named as a string or symbol, as with `to:`, so drawing the routes does not load the controller class.

## One controller per service

```ruby
# config/routes.rb
Rails.application.routes.draw do
  connect_service "greet.v1.GreetService" => :greet
end
```

Each RPC becomes `/<pkg.Service>/<Method>`, here `POST /greet.v1.GreetService/SayHello` to `GreetController#say_hello`. Several services can be mapped in one call:

```ruby
connect_service "greet.v1.GreetService" => :greet,
  "billing.v1.InvoiceService" => :invoices
```

## One controller per RPC

When a service's methods have little in common, such as different authorization, give each its own controller with a block. Each controller then declares its own callbacks instead of sharing the service's with `only:`.

```ruby
# config/routes.rb
connect_service "greet.v1.GreetService" do
  rpc "SayHello" => :greet_say_hello
  rpc "SayGoodbye" => :greet_say_goodbye
end
```

`connect_service` on the controller side is inherited, so declare it once on a shared base class:

```ruby
# app/controllers/greet_base_controller.rb
class GreetBaseController < ActionController::API
  include ConnectRpcRails::Controller

  connect_service "greet.v1.GreetService"
end

# app/controllers/greet_say_hello_controller.rb
class GreetSayHelloController < GreetBaseController
  def say_hello
    Greet::V1::SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
  end
end
```

Every name in the block must be an RPC the descriptor declares, so a typo or a renamed method raises at boot. The block does not have to cover the whole service: an RPC left out is routed to the first mapped controller.

## What each request is answered

| Request | Answer |
|---|---|
| `POST` to a declared RPC the controller implements | The action's response |
| `POST` to a declared RPC the controller does not implement | Connect `unimplemented` (HTTP 501) |
| Any verb to a method the descriptor does not declare, under the service's prefix | 404 |
| A non-`POST` verb to a declared RPC | 405 |
| A content type other than `application/json` or `application/proto` | 415 |

The catch-all and the unimplemented answer are controller actions, so the controller's own callbacks run first: with authentication in a `before_action`, an unauthenticated caller is answered `unauthenticated` instead. The 405 and 415 checks run ahead of every callback.

The method list lives only in the `.proto`. Adding an RPC to the descriptor routes it immediately, and it is answered `unimplemented` until the controller defines the action.

## Boot-time checks

Under eager loading (production, and CI when `config.eager_load` is on), drawing the routes also resolves each mapped controller and checks that it declares the service it was wired to. A controller without `connect_service`, or one serving a different service, raises at boot. Rails eager loads before drawing the routes, so the check autoloads nothing. With lazy loading (development) the controller class is left untouched.
