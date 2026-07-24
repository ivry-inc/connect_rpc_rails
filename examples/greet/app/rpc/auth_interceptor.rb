# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module Greet
  module V1
    # Stands in for real bearer verification: it authenticates the Bearer
    # token and writes the resulting principal onto the context for the handler to
    # read. This is the authN edge; authZ (scoping to the principal) belongs in the
    # handler. "principal" is just a convention on the context values bag, not a
    # library concept.
    class AuthInterceptor < ConnectRpcRails::Interceptor
      # verifier: a callable token -> principal (or nil). In production this is
      # your bearer/JWKS verification returning a scoped Principal.
      def initialize(&verifier)
        super()
        @verifier = verifier
      end

      def call(request, context, nxt)
        header = context.metadata['authorization'].to_s
        token = header.start_with?('Bearer ') ? header.delete_prefix('Bearer ') : nil
        principal = token && @verifier.call(token)
        raise ConnectRpcRails::Error.new(:unauthenticated, 'missing or invalid bearer token') unless principal

        context[:principal] = principal
        nxt.call(request, context)
      end
    end

    # Stand-in for the real bearer verifier the controller wires into AuthInterceptor.
    # In production this is your bearer/JWKS verification returning a
    # scoped Principal; here a valid token maps to a fixed user.
    TOKEN_VERIFIER = ->(token) { token == 'valid-token' ? 'user:99' : nil }
  end
end
