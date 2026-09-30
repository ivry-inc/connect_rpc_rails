# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "google/protobuf"
require "google/protobuf/descriptor_pb"
require "buf/validate/validate_pb"

# Stands in for `buf generate` over a greet service carrying buf.validate rules, built by hand
# like the example's greet_pb.rb so the suite needs no protoc toolchain. The multi-word, repeated
# and map fields are what make a published field path distinguishable from the proto one.
module Validated
  module V1
    def self.field(name, number, json_name:, type: :TYPE_STRING, label: :LABEL_OPTIONAL, **rest)
      Google::Protobuf::FieldDescriptorProto.new(name:, number:, json_name:, type:, label:, **rest)
    end

    def self.min_len(length)
      options = Google::Protobuf::FieldOptions.new
      rules = Buf::Validate::FieldRules.new(string: Buf::Validate::StringRules.new(min_len: length))
      Google::Protobuf::DescriptorPool.generated_pool.lookup("buf.validate.field").set(options, rules)
      options
    end

    file = Google::Protobuf::FileDescriptorProto.new(
      name: "validated/v1/validated_greet.proto",
      package: "validated.v1",
      syntax: "proto3",
      dependency: ["buf/validate/validate.proto"],
      message_type: [
        Google::Protobuf::DescriptorProto.new(
          name: "Part",
          field: [field("part_name", 1, json_name: "partName", options: min_len(1))],
        ),
        Google::Protobuf::DescriptorProto.new(
          name: "SayHelloRequest",
          field: [
            field("name", 1, json_name: "name", options: min_len(1)),
            field("preferred_language", 2, json_name: "preferredLanguage", options: min_len(2)),
            field(
              "parts",
              3,
              json_name: "parts",
              type: :TYPE_MESSAGE,
              type_name: ".validated.v1.Part",
              label: :LABEL_REPEATED,
            ),
            field(
              "labels",
              4,
              json_name: "labels",
              type: :TYPE_MESSAGE,
              type_name: ".validated.v1.SayHelloRequest.LabelsEntry",
              label: :LABEL_REPEATED,
            ),
          ],
          nested_type: [
            Google::Protobuf::DescriptorProto.new(
              name: "LabelsEntry",
              options: Google::Protobuf::MessageOptions.new(map_entry: true),
              field: [
                field("key", 1, json_name: "key"),
                field("value", 2, json_name: "value", type: :TYPE_MESSAGE, type_name: ".validated.v1.Part"),
              ],
            ),
          ],
        ),
        Google::Protobuf::DescriptorProto.new(
          name: "SayHelloResponse",
          field: [field("greeting", 1, json_name: "greeting")],
        ),
      ],
      service: [
        Google::Protobuf::ServiceDescriptorProto.new(
          name: "ValidatedGreetService",
          method: [
            Google::Protobuf::MethodDescriptorProto.new(
              name: "SayHello",
              input_type: ".validated.v1.SayHelloRequest",
              output_type: ".validated.v1.SayHelloResponse",
            ),
          ],
        ),
      ],
    )
    pool = Google::Protobuf::DescriptorPool.generated_pool
    pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))

    Part = pool.lookup("validated.v1.Part").msgclass
    SayHelloRequest = pool.lookup("validated.v1.SayHelloRequest").msgclass
    SayHelloResponse = pool.lookup("validated.v1.SayHelloResponse").msgclass
  end
end
