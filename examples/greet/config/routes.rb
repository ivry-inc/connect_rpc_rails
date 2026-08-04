# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

Rails.application.routes.draw do
  # 1 RPC = 1 route, one route per method the descriptor declares: this draws
  #   POST /greet.v1.GreetService/SayHello => GreetController#say_hello
  # so a wrong verb is a 405 and no custom dispatcher is involved. The controller is named
  # as a string, as in any other Rails route, so drawing the routes doesn't load the class.
  # The service prefix also gets one catch-all, which 404s a method the service never
  # declared.
  connect_service "greet.v1.GreetService" => :greet
end
