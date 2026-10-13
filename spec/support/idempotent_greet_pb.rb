# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "google/protobuf"
require "google/protobuf/descriptor_pb"

# Stands in for `buf generate` over a greet service whose RPCs declare an idempotency level,
# built by hand like the example's greet_pb.rb. Only NO_SIDE_EFFECTS on a unary RPC lets a
# Connect client call it with GET. It reuses the example's messages.
module IdempotentGreet
  SERVICE_NAME = "greet.v1.IdempotentGreetService"

  def self.method_descriptor(name, idempotency_level, **extra)
    Google::Protobuf::MethodDescriptorProto.new(
      name:,
      input_type: ".greet.v1.SayHelloRequest",
      output_type: ".greet.v1.SayHelloResponse",
      options: Google::Protobuf::MethodOptions.new(idempotency_level:),
      **extra,
    )
  end

  file = Google::Protobuf::FileDescriptorProto.new(
    name: "greet/v1/idempotent_greet.proto",
    package: "greet.v1",
    syntax: "proto3",
    dependency: ["greet/v1/greet.proto"],
    service: [
      Google::Protobuf::ServiceDescriptorProto.new(
        name: "IdempotentGreetService",
        method: [
          method_descriptor("SayHello", :NO_SIDE_EFFECTS),
          method_descriptor("SaveGreeting", :IDEMPOTENT),
          method_descriptor("WatchGreetings", :NO_SIDE_EFFECTS, server_streaming: true),
        ],
      ),
    ],
  )
  Google::Protobuf::DescriptorPool.generated_pool
    .add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
end
