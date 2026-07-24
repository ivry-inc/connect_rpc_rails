#!/usr/bin/env ruby
# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

# Server-under-test executable for the Connect conformance runner (--mode server).
# Contract: read one length-prefixed ServerCompatRequest from stdin, start an HTTP
# server implementing ConformanceService, then write a length-prefixed
# ServerCompatResponse (host/port) to stdout. Exit on SIGTERM.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("gen", __dir__))

require "connect_rpc_rails"
require "action_dispatch"
require "connectrpc/conformance/v1/server_compat_pb"
require "connectrpc/conformance/v1/service_pb"
require_relative "service_handler"
require "puma"

V1 = Connectrpc::Conformance::V1

$stdin.binmode
# The length-prefixed protocol uses stdout; reopen $stdout to stderr first so
# nothing else (e.g. Puma logging) can corrupt that channel.
protocol_out = $stdout.dup
protocol_out.binmode
$stdout.reopen($stderr)

length = $stdin.read(4).unpack1("N")
_request = V1::ServerCompatRequest.decode($stdin.read(length))

DESCRIPTOR = Google::Protobuf::DescriptorPool.generated_pool.lookup("connectrpc.conformance.v1.ConformanceService")

class ConformanceController < ActionController::API
  include ConnectRpcRails::Controller
  connect_service DESCRIPTOR, handler: Conformance::ServiceHandler.new
end

routes = ActionDispatch::Routing::RouteSet.new
routes.draw do
  ConnectRpcRails::Routing.mount(self, ConformanceController)
end

server = Puma::Server.new(routes)
listener = server.add_tcp_listener("127.0.0.1", 0)
server.run

response = V1::ServerCompatResponse.encode(V1::ServerCompatResponse.new(host: "127.0.0.1", port: listener.addr[1]))
protocol_out.write([response.bytesize].pack("N"))
protocol_out.write(response)
protocol_out.flush

['TERM', 'INT'].each do |sig|
  trap(sig) do
    server.stop(true)
    exit(0)
  end
end
sleep
