# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "tapioca/internal"
require "tapioca/helpers/test/dsl_compiler"
require "tapioca/dsl/compilers/connect_rpc_rails_controller"

# A service whose RPCs take different messages, reusing the example's.
Google::Protobuf::DescriptorPool.generated_pool.add_serialized_file(
  Google::Protobuf::FileDescriptorProto.encode(
    Google::Protobuf::FileDescriptorProto.new(
      name: "greet/v1/mixed_input_greet.proto",
      package: "greet.v1",
      syntax: "proto3",
      dependency: ["greet/v1/greet.proto"],
      service: [
        Google::Protobuf::ServiceDescriptorProto.new(
          name: "MixedInputGreetService",
          method: [
            Google::Protobuf::MethodDescriptorProto.new(
              name: "SayHello",
              input_type: ".greet.v1.SayHelloRequest",
              output_type: ".greet.v1.SayHelloResponse",
            ),
            Google::Protobuf::MethodDescriptorProto.new(
              name: "EchoGreeting",
              input_type: ".greet.v1.SayHelloResponse",
              output_type: ".greet.v1.SayHelloResponse",
            ),
          ],
        ),
      ],
    ),
  ),
)

class SingleInputCompilerTestController < ActionController::API
  include ConnectRpcRails::Controller

  connect_service "greet.v1.GreetService"
end

class MixedInputCompilerTestController < ActionController::API
  include ConnectRpcRails::Controller

  connect_service "greet.v1.MixedInputGreetService"
end

class NoServiceCompilerTestController < ActionController::API
  include ConnectRpcRails::Controller
end

RSpec.describe(Tapioca::Dsl::Compilers::ConnectRpcRailsController) do
  let(:context) { Tapioca::Helpers::Test::DslCompiler::CompilerContext.new(described_class) }

  it "gathers only controllers that declare a service" do
    expect(context.gathered_constants).to include("SingleInputCompilerTestController", "MixedInputCompilerTestController")
    expect(context.gathered_constants).not_to include("NoServiceCompilerTestController")
  end

  it "types connect_request as the one class a controller's RPCs take" do
    expect(context.rbi_for(:SingleInputCompilerTestController)).to eq(<<~RBI)
      # typed: strong

      class SingleInputCompilerTestController
        private

        sig { returns(::Greet::V1::SayHelloRequest) }
        def connect_request; end
      end
    RBI
  end

  it "types connect_request as the union when RPCs take different classes" do
    expect(context.rbi_for(:MixedInputCompilerTestController)).to eq(<<~RBI)
      # typed: strong

      class MixedInputCompilerTestController
        private

        sig { returns(T.any(::Greet::V1::SayHelloRequest, ::Greet::V1::SayHelloResponse)) }
        def connect_request; end
      end
    RBI
  end
end
