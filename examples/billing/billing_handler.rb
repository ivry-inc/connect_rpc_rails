# frozen_string_literal: true

module Billing
  module V1
    # Plain Ruby object — NOT an ActionController action. The handler is defined by
    # the Connect contract, not the transport: it never touches HTTP, so the same
    # object works over any transport (loopback HTTP today, a separate service
    # tomorrow) with no change. AuthN has already happened by the time we get here;
    # authZ (scoping the write to the principal's realm) would live in this method,
    # reading context[:principal].
    class BillingHandler
      def ingest_usage(request, _context)
        if request.payer_external_id.empty?
          raise ConnectRpc::Error.new(
            :invalid_argument,
            'payer_external_id is required',
          )
        end
        raise ConnectRpc::Error.new(:invalid_argument, 'quantity must be positive') if request.quantity <= 0
        raise ConnectRpc::Error.new(:invalid_argument, 'idempotency_key is required') if request.idempotency_key.empty?

        # e.g. authorize!(context[:principal], payer: request.payer_external_id)
        IngestUsageResponse.new(
          usage_event_id: "evt_#{request.idempotency_key}",
          accepted: true,
        )
      end
    end
  end
end
