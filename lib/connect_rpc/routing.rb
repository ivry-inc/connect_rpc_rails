# frozen_string_literal: true
# rbs_inline: enabled

module ConnectRpc
  # Declares the Connect routes for a service: one `POST /<pkg.Service>/<Method>`
  # per RPC, mapped to `<controller>#<underscored_method>` (1 RPC = 1 action). Call
  # inside a Rails `routes.draw` block:
  #
  #   Rails.application.routes.draw do
  #     ConnectRpc::Routing.mount(self, Billing::V1::SERVICE_DESCRIPTOR, controller: "billing")
  #   end
  #
  # `format: false` keeps the dots in the service name from being parsed as a format
  # suffix. An unlisted method never matches, so it's a plain 404. Routes match every
  # verb (`via: :all`) so a wrong-verb request reaches the controller and becomes a
  # Connect-correct 405 rather than a router 404.
  module Routing
    #: (untyped mapper, untyped descriptor, controller: String) -> void
    def self.mount(mapper, descriptor, controller:)
      descriptor.each do |method|
        mapper.match(
          "/#{descriptor.name}/#{method.name}",
          to: "#{controller}##{ConnectRpc.underscore(method.name)}",
          via: :all,
          format: false,
        )
      end
    end
  end
end
