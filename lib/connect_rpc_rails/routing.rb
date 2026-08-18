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
  # A block maps the RPCs to a controller each, for a service whose methods are better off
  # not sharing one class — an RPC then gets its own `before_action`s rather than callbacks
  # the whole service runs with `only:`:
  #
  #   connect_service "greet.v1.GreetService" do
  #     rpc "SayHello" => :greet_say_hello
  #     rpc "SayGoodbye" => :greet_say_goodbye
  #   end
  #
  # Every mapped name has to be one the descriptor declares, so a typo or a rename fails at
  # boot rather than drawing a route nothing reaches. The mapping does not have to cover the
  # service: an RPC left out is routed to the first mapped controller, which serves the
  # service but not that method, so it is answered `unimplemented` the way a declared RPC
  # nobody implements always is.
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

    #: (Hash[String | Symbol, String | Symbol] | String | Symbol) ?{ (?MethodMapping) [self: MethodMapping] -> void } -> void
    def connect_service(mapping, &block)
      if block
        unless mapping.is_a?(String) || mapping.is_a?(Symbol)
          raise ArgumentError, "connect_service takes a service name with a block, not a controller mapping"
        end

        return Service.new(self, mapping.to_s, MethodMapping.collect(&block)).draw
      end

      unless mapping.is_a?(Hash)
        raise ArgumentError, "connect_service takes a service-to-controller mapping, or a service name with a block"
      end

      mapping.each do |service_name, controller|
        Service.new(self, service_name.to_s, controller.to_s).draw
      end
    end

    # Collects the per-RPC controller mapping a `connect_service` block declares. `rpc`
    # takes the method name as the `.proto` spells it, so both ends of the mapping grep to
    # the protobuf definition.
    class MethodMapping
      #: () { (?MethodMapping) [self: MethodMapping] -> void } -> Hash[String, String]
      def self.collect(&block)
        collector = new
        collector.instance_eval(&block)
        collector.mapping
      end

      attr_reader :mapping #: Hash[String, String]

      #: () -> void
      def initialize
        @mapping = {} #: Hash[String, String]
      end

      #: (Hash[String | Symbol, String | Symbol]) -> void
      def rpc(mapping)
        mapping.each { |name, controller| @mapping[name.to_s] = controller.to_s }
      end
    end

    # Draws the routes for one service: every RPC the descriptor declares, then the
    # catch-all. The RPCs go to one controller, or to the controller each is mapped to.
    class Service
      #: (untyped mapper, String service_name, String | Hash[String, String] controllers) -> void
      def initialize(mapper, service_name, controllers)
        @mapper = mapper
        @controllers = controllers
        @registration = ServiceRegistration.new(service_name)
        verify_mapping! if controllers.is_a?(Hash)
      end

      #: () -> void
      def draw
        @registration.rpcs.each { |rpc| route(rpc.name, rpc.action, controller_for(rpc.name)) }
        # The catch-all renders a 404 and nothing else, which any controller serving the
        # service answers identically, so it goes to the first one mapped.
        route("*#{Controller::UNKNOWN_METHOD_PARAM}", Controller::UNKNOWN_METHOD_ACTION, controller_paths.first)

        return unless Routing.verify_controllers?

        controller_paths.each { |path| Routing.verify_controller!(@registration.service_name, path) }
      end

      # A mapping is checked against the descriptor as the routes are drawn: a controller
      # mapped to a name the service does not declare is a typo or a rename, and it would
      # otherwise draw a route nothing can reach. An RPC the block leaves out is *not* an
      # error — it is routed too (see #controller_for), because a declared RPC nobody
      # implements is what Connect answers `unimplemented`.
      #: () -> void
      private def verify_mapping!
        raise ArgumentError, "#{@registration.service_name} is mapped to no controller" if @controllers.empty?

        undeclared = @controllers.keys - @registration.rpcs.map(&:name)
        return if undeclared.empty?

        raise ArgumentError, "#{@registration.service_name} declares no RPC named #{undeclared.join(", ")}"
      end

      # An RPC the mapping leaves out still gets a route, at the first mapped controller:
      # it serves the service but not that method, so #action_missing answers it
      # `unimplemented` (501) exactly as the protocol wants — where no route at all would
      # have made it a 404.
      #: (String) -> String
      private def controller_for(rpc_name)
        return @controllers unless @controllers.is_a?(Hash)

        @controllers.fetch(rpc_name) { controller_paths.first }
      end

      #: () -> Array[String]
      private def controller_paths
        @controllers.is_a?(Hash) ? @controllers.values.uniq : [@controllers]
      end

      # Routes match every verb (`via: :all`) so a wrong-verb request reaches the
      # controller and becomes a Connect-correct 405 rather than a router 404.
      # `format: false` keeps the dots in the service name from being parsed as a format
      # suffix.
      #: (String, String, String) -> void
      private def route(path, action, controller_path)
        @mapper.match(
          "/#{@registration.service_name}/#{path}",
          to: "#{controller_path}##{action}",
          via: :all,
          format: false,
        )
      end
    end
  end
end
