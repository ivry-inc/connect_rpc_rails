# frozen_string_literal: true

require 'google/protobuf'
require 'google/protobuf/descriptor_pb'

# Stands in for the output of `buf generate` / `protoc --ruby_out`. A real project
# would generate this from a billing/v1/billing.proto; here we build the
# FileDescriptorProto by hand so the prototype needs no protoc toolchain. The
# important part is what it proves: once the service is in the descriptor pool, the
# server routes and finds message types purely by reflection (see ServiceRegistration).
module Billing
  module V1
    file = Google::Protobuf::FileDescriptorProto.new(
      name: 'billing/v1/billing.proto',
      package: 'billing.v1',
      syntax: 'proto3',
      message_type: [
        Google::Protobuf::DescriptorProto.new(
          name: 'IngestUsageRequest',
          field: [
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'payer_external_id',
              number: 1,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'product',
              number: 2,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'metric',
              number: 3,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'quantity',
              number: 4,
              label: :LABEL_OPTIONAL,
              type: :TYPE_INT64,
            ),
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'idempotency_key',
              number: 5,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
          ],
        ),
        Google::Protobuf::DescriptorProto.new(
          name: 'IngestUsageResponse',
          field: [
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'usage_event_id',
              number: 1,
              label: :LABEL_OPTIONAL,
              type: :TYPE_STRING,
            ),
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'accepted',
              number: 2,
              label: :LABEL_OPTIONAL,
              type: :TYPE_BOOL,
            ),
          ],
        ),
      ],
      service: [
        Google::Protobuf::ServiceDescriptorProto.new(
          name: 'BillingService',
          method: [
            Google::Protobuf::MethodDescriptorProto.new(
              name: 'IngestUsage',
              input_type: '.billing.v1.IngestUsageRequest',
              output_type: '.billing.v1.IngestUsageResponse',
            ),
          ],
        ),
      ],
    )

    pool = Google::Protobuf::DescriptorPool.generated_pool
    pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))

    IngestUsageRequest = pool.lookup('billing.v1.IngestUsageRequest').msgclass
    IngestUsageResponse = pool.lookup('billing.v1.IngestUsageResponse').msgclass
    SERVICE_DESCRIPTOR = pool.lookup('billing.v1.BillingService')
  end
end
