# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "active_support/core_ext/string/inflections"

module ConnectRpcRails
  # Routes DSL for one Connect service, installed on the Rails routes mapper. The service
  # is named as the `.proto` names it and mapped to a controller the way Rails' own `to:`
  # names one — as a string, so drawing the routes doesn't load the controller class:
  #
  #   Rails.application.routes.draw do
  #     connect_service "greet.v1.GreetService" => :greet
  #   end
  #
  # Every RPC the descriptor declares becomes one `POST /<pkg.Service>/<Method>` route to
  # the action implementing it (1 RPC = 1 action), so the protobuf definition is the only
  # place the method list lives. A declared RPC the controller doesn't implement is
  # answered Connect `unimplemented` by the controller, not by a route. After the RPC
  # routes comes one catch-all over the service prefix, which is where a method the
  # descriptor never declared becomes a 404.
  module Routing
    # Whether the routed controllers can be resolved right now. Only under eager loading:
    # Rails eager loads before it draws the routes, so the classes are already in memory
    # and constantizing one autoloads nothing. With lazy loading (dev, and a plain Rack
    # host) the class is deliberately left untouched.
    #: () -> bool
    def self.verify_controllers?
      return false unless defined?(::Rails.application)

      !!::Rails.application&.config&.eager_load
    end

    # Checks that each routed service resolves to a controller that actually serves it, so
    # a service wired to the wrong controller fails at boot instead of 404-ing in
    # production. Called as the routes are drawn (see .verify_controllers?).
    #: (String, String) -> void
    def self.verify_controller!(service_name, controller_path)
      controller = "#{controller_path.camelize}Controller".constantize
      registration = controller.connect_registration if controller.respond_to?(:connect_registration)
      unless registration
        raise ArgumentError, "#{controller} does not serve a Connect service: it needs `connect_service`"
      end
      unless registration.service_name == service_name
        raise ArgumentError, "#{controller} serves #{registration.service_name}, not #{service_name}"
      end
    end

    #: (Hash[String | Symbol, String | Symbol]) -> void
    def connect_service(mapping)
      mapping.each do |service_name, controller|
        Service.new(self, service_name.to_s, controller.to_s).draw
      end
    end

    # Draws the routes for one service: every RPC the descriptor declares, then the
    # catch-all.
    class Service
      #: (untyped mapper, String service_name, String controller_path) -> void
      def initialize(mapper, service_name, controller_path)
        @mapper = mapper
        @controller_path = controller_path
        @registration = ServiceRegistration.new(service_name)
      end

      #: () -> void
      def draw
        @registration.rpcs.each { |rpc| route(rpc.name, rpc.action) }
        route("*#{Controller::UNKNOWN_METHOD_PARAM}", Controller::UNKNOWN_METHOD_ACTION)

        Routing.verify_controller!(@registration.service_name, @controller_path) if Routing.verify_controllers?
      end

      # Routes match every verb (`via: :all`) so a wrong-verb request reaches the
      # controller and becomes a Connect-correct 405 rather than a router 404.
      # `format: false` keeps the dots in the service name from being parsed as a format
      # suffix.
      #: (String, String) -> void
      private def route(path, action)
        @mapper.match(
          "/#{@registration.service_name}/#{path}",
          to: "#{@controller_path}##{action}",
          via: :all,
          format: false,
        )
      end
    end
  end
end
