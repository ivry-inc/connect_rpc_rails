# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module ConnectRpc
  # Declares the Connect routes for a controller: one `POST /<pkg.Service>/<Method>`
  # per RPC, mapped to `<controller>#<underscored_method>` (1 RPC = 1 action). The
  # service name, methods, and controller path all come from the controller's
  # `connect_service`, so the descriptor lives in exactly one place. Call inside a
  # Rails `routes.draw` block:
  #
  #   Rails.application.routes.draw do
  #     ConnectRpc::Routing.mount(self, GreetController)
  #   end
  #
  # `format: false` keeps the dots in the service name from being parsed as a format
  # suffix. An unlisted method never matches, so it's a plain 404. Routes match every
  # verb (`via: :all`) so a wrong-verb request reaches the controller and becomes a
  # Connect-correct 405 rather than a router 404.
  module Routing
    #: (untyped mapper, untyped controller) -> void
    def self.mount(mapper, controller)
      service_name = controller.connect_registration.service_name
      controller.connect_rpcs.each do |action, rpc|
        mapper.match(
          "/#{service_name}/#{rpc.name}",
          to: "#{controller.controller_path}##{action}",
          via: :all,
          format: false,
        )
      end
    end
  end
end
