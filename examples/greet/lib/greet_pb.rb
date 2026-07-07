# frozen_string_literal: true

require 'google/protobuf'
require 'google/protobuf/descriptor_pb'

# Stands in for the output of `buf generate` / `protoc --ruby_out` for the sibling
# proto/greet/v1/greet.proto. A real project would generate this file; here we build
# the FileDescriptorProto by hand so the example needs no protoc toolchain. The
# important part is what it proves: once the service is in the descriptor pool, the
# server routes and finds message types purely by reflection (see ServiceRegistration).
module Greet
  module V1
    file = Google::Protobuf::FileDescriptorProto.new(
      name: 'greet/v1/greet.proto',
      package: 'greet.v1',
      syntax: 'proto3',
      message_type: [
        Google::Protobuf::DescriptorProto.new(
          name: 'SayHelloRequest',
          field: [
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'name',
              number: 1,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'preferred_language',
              number: 2,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
          ],
        ),
        Google::Protobuf::DescriptorProto.new(
          name: 'SayHelloResponse',
          field: [
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'greeting',
              number: 1,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
          ],
        ),
      ],
      service: [
        Google::Protobuf::ServiceDescriptorProto.new(
          name: 'GreetService',
          method: [
            Google::Protobuf::MethodDescriptorProto.new(
              name: 'SayHello',
              input_type: '.greet.v1.SayHelloRequest',
              output_type: '.greet.v1.SayHelloResponse',
            ),
          ],
        ),
      ],
    )

    pool = Google::Protobuf::DescriptorPool.generated_pool
    pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))

    SayHelloRequest = pool.lookup('greet.v1.SayHelloRequest').msgclass
    SayHelloResponse = pool.lookup('greet.v1.SayHelloResponse').msgclass
    SERVICE_DESCRIPTOR = pool.lookup('greet.v1.GreetService')
  end
end
