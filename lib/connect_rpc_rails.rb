# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require 'connect_rpc_rails/version'
require 'connect_rpc_rails/errors'
require 'connect_rpc_rails/context'
require 'connect_rpc_rails/codec'
require 'connect_rpc_rails/service_registration'
require 'connect_rpc_rails/interceptor'
require 'connect_rpc_rails/exception_mapping_interceptor'
require 'connect_rpc_rails/controller'
require 'connect_rpc_rails/routing'

module ConnectRpcRails
  # "SayHello" -> "say_hello". Maps a Connect method name to its Ruby handler
  # method so dispatch stays reflection-driven (no per-service codegen).
  #: (String) -> String
  def self.underscore(name)
    name.to_s
      .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
      .downcase
  end
end
