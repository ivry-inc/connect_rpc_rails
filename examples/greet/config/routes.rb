# frozen_string_literal: true

Rails.application.routes.draw do
  # 1 RPC = 1 route, derived from the controller's service descriptor. This mounts
  #   POST /greet.v1.GreetService/SayHello => GreetController#say_hello
  # so an unknown method is a plain Rails 404 and a wrong verb is a 405 — no custom
  # dispatcher. `mount` reads the routes straight off the controller class.
  ConnectRpc::Routing.mount(self, GreetController)
end
