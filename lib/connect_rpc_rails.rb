# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require 'connect_rpc_rails/version'
require 'connect_rpc_rails/errors'
require 'connect_rpc_rails/codec'
require 'connect_rpc_rails/service_registration'
require 'connect_rpc_rails/controller'
require 'connect_rpc_rails/routing'

module ConnectRpcRails
  # Installs what the gem adds to Action Dispatch: the routes DSL, and Connect's binary
  # content-type so `request.format` (and thus the instrumentation payload / request log)
  # reports :proto instead of defaulting to :html. In a Rails app the Railtie calls this
  # during boot; a plain Rack host (or a spec) calls it itself.
  #: () -> void
  def self.install!
    require 'action_dispatch'

    ActionDispatch::Routing::Mapper.include(Routing)
    Mime::Type.register('application/proto', :proto) unless Mime[:proto]
  end

  # "SayHello" -> "say_hello". Maps a Connect method name to the controller action
  # implementing it, so dispatch stays reflection-driven (no per-service codegen).
  #: (String) -> String
  def self.underscore(name)
    name.to_s
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .downcase
  end
end

require 'connect_rpc_rails/railtie' if defined?(Rails::Railtie)
