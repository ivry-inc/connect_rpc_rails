# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

# Stands in for real bearer verification: authenticates the Bearer token and exposes the
# resulting principal to the RPC methods. This is the authN edge; authZ (scoping to the
# principal) belongs in the RPC method.
#
# A concern with a `before_action` is all an "interceptor" is here — cross-cutting logic
# that runs for every RPC on the controller. Being a Rails callback, it also gets `only:`
# / `except:` and `skip_before_action` in controllers that need a public RPC, and the
# principal is an ordinary instance variable rather than an entry in a context bag.
module BearerAuthentication
  extend ActiveSupport::Concern

  included do
    # verifier: a callable token -> principal (or nil). In production this is your
    # bearer/JWKS verification returning a scoped Principal.
    class_attribute :token_verifier

    before_action :authenticate_bearer_token
  end

  # Raises rather than halting the chain with `throw :abort`, so the response comes from
  # the same `rescue_from` that renders an RPC's own errors.
  private def authenticate_bearer_token
    header = request.headers['Authorization'].to_s
    token = header.start_with?('Bearer ') ? header.delete_prefix('Bearer ') : nil
    @principal = token && token_verifier.call(token)
    return if @principal

    raise ConnectRpcRails::Error.new(:unauthenticated, 'missing or invalid bearer token')
  end

  # The authenticated principal, for the RPC methods to authorize against.
  private attr_reader :principal
end
