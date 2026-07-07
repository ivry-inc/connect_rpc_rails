# frozen_string_literal: true
# rbs_inline: enabled

require 'connect_rpc/version'
require 'connect_rpc/errors'
require 'connect_rpc/context'
require 'connect_rpc/codec'
require 'connect_rpc/service_registration'
require 'connect_rpc/interceptor'
require 'connect_rpc/exception_mapping_interceptor'
require 'connect_rpc/controller'
require 'connect_rpc/routing'

module ConnectRpc
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
