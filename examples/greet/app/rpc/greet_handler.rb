# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module Greet
  module V1
    # Plain Ruby object — NOT an ActionController action. The handler is defined by
    # the Connect contract, not the transport: it never touches HTTP, so the same
    # object works over any transport (loopback HTTP today, a separate service
    # tomorrow) with no change. AuthN has already happened by the time we get here;
    # authZ (e.g. scoping to the principal) would live in this method, reading
    # context[:principal].
    class GreetHandler
      SALUTATIONS = {'es' => 'Hola', 'fr' => 'Bonjour', 'ja' => 'こんにちは'}.freeze

      def say_hello(request, _context)
        raise ConnectRpc::Error.new(:invalid_argument, 'name is required') if request.name.empty?

        # e.g. authorize!(context[:principal])
        salutation = SALUTATIONS.fetch(request.preferred_language, 'Hello')
        SayHelloResponse.new(greeting: "#{salutation}, #{request.name}!")
      end
    end
  end
end
