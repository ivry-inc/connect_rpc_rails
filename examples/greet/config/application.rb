# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "rails"
# An RPC endpoint skips the browser railties (views, assets, sessions). Load just
# Action Controller and Active Record — the controller maps ActiveRecord::RecordNotFound
# to a Connect code, and a real service has a database behind it.
require "active_record/railtie"
require "action_controller/railtie"
require "connect_rpc_rails"

# The protobuf descriptor (normally the output of `buf generate` / `protoc`) has to be in
# the pool before `connect_service` looks the service up by name — in the routes file and
# at controller load.
require_relative "../lib/greet_pb"

module Greet
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
  end
end
