# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "rails/railtie"

module ConnectRpcRails
  # Hooks the gem into a Rails app at the framework's own boot point rather than by
  # patching Action Dispatch when the gem is required: the initializer runs once the
  # frameworks are loaded and before the routes are drawn, which is all the routes DSL
  # needs.
  class Railtie < ::Rails::Railtie
    initializer "connect_rpc_rails.install" do
      ConnectRpcRails.install!
    end
  end
end
