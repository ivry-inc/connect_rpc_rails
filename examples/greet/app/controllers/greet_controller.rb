# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

# A Connect service is just an ActionController::API controller: each RPC in the
# descriptor is one Rails action, so every call flows through the normal controller
# lifecycle — `before_action`/`around_action` callbacks, `rescue_from`, and
# `process_action.action_controller` instrumentation all apply for free. Cross-cutting
# concerns are exactly that: authN is a concern with a `before_action`, and mapping domain
# exceptions to Connect codes is `rescue_from`.
#
# The RPC methods are ordinary instance methods taking no arguments, so they run on the
# per-request instance Rails builds for every action: nothing an RPC leaves behind can be
# read by the next caller. AuthN has already happened by the time an RPC method runs;
# authZ (e.g. scoping to the principal) lives here, reading `principal`.
class GreetController < ActionController::API
  include ConnectRpcRails::Controller
  include BearerAuthentication

  SALUTATIONS = {'es' => 'Hola', 'fr' => 'Bonjour', 'ja' => 'こんにちは'}.freeze

  connect_service 'greet.v1.GreetService'

  # No mapping for ActiveRecord::RecordNotFound: Rails already classifies it in
  # `config.action_dispatch.rescue_responses`, so it is a Connect `not_found` here without
  # being restated. `map_connect_errors MyDomain::Invalid => :invalid_argument` is for the
  # exceptions Rails knows nothing about.

  # In production this is your bearer/JWKS verification returning a scoped Principal;
  # here a valid token maps to a fixed user.
  self.token_verifier = ->(token) { token == 'valid-token' ? 'user:99' : nil }

  def say_hello
    raise ConnectRpcRails::Error.new(:invalid_argument, 'name is required') if connect_request.name.empty?

    # e.g. authorize!(principal)
    salutation = SALUTATIONS.fetch(connect_request.preferred_language, 'Hello')
    Greet::V1::SayHelloResponse.new(greeting: "#{salutation}, #{connect_request.name}!")
  end
end
