# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

return unless defined?(ConnectRpcRails::Controller)

module Tapioca
  module Dsl
    module Compilers
      # Types `connect_request` on each controller that declares `connect_service`, so an RPC
      # reads the decoded request as its message class without a cast.
      #
      # A controller whose RPCs take one message class gets that class:
      #
      # ~~~rb
      # class GreetController < ActionController::API
      #   include ConnectRpcRails::Controller
      #   connect_service "greet.v1.GreetService"
      #
      #   def say_hello; end
      # end
      # ~~~
      #
      # ~~~rbi
      # # greet_controller.rbi
      # # typed: true
      # class GreetController
      #   private
      #
      #   sig { returns(::Greet::V1::SayHelloRequest) }
      #   def connect_request; end
      # end
      # ~~~
      #
      # A controller whose RPCs take different classes gets their union, which an action
      # narrows itself, for example with `#: self as GreetController & ...` or a cast.
      #: [ConstantType = Class[top]]
      class ConnectRpcRailsController < Compiler
        # @override
        #: -> void
        def decorate
          root.create_path(constant) do |controller|
            controller.create_method("connect_request", return_type: return_type, visibility: RBI::Private.new)
          end
        end

        class << self
          # @override
          #: -> Enumerable[Module[top]]
          def gather_constants
            all_classes.select do |klass|
              klass < ::ConnectRpcRails::Controller && !input_classes(klass).empty?
            end
          end

          #: (Class[top] klass) -> Array[Module[top]]
          def input_classes(klass)
            (klass.connect_rpcs || {}).values.map(&:input_class).uniq
          end
        end

        #: -> String
        private def return_type
          names = self.class.input_classes(constant).map { |klass| "::#{klass.name}" }.sort
          names.one? ? names.first : "T.any(#{names.join(", ")})"
        end
      end
    end
  end
end
