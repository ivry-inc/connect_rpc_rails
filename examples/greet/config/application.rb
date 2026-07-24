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

# The protobuf descriptor (normally the output of `buf generate` / `protoc`) has to be
# in the pool before the controller's `connect_service` reads it at class-load time.
require_relative "../lib/greet_pb"

module Greet
  class Application < Rails::Application
    config.load_defaults 7.2
    config.api_only = true

    # Autoload the handlers and interceptors in app/rpc alongside app/controllers.
    config.autoload_paths << root.join("app/rpc")
  end
end
