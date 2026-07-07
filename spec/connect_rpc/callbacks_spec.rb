# frozen_string_literal: true

RSpec.describe ConnectRpc::Callbacks do
  include BillingHelpers

  # Records the lifecycle into context[:events]; reject_zero halts on quantity 0.
  let(:handler_class) do
    Class.new do
      include ConnectRpc::Callbacks

      before_action :track_before
      around_action :track_around
      after_action :track_after
      before_action :reject_zero, only: [:ingest_usage]

      def ingest_usage(request, context)
        (context[:events] ||= []) << :action
        Billing::V1::IngestUsageResponse.new(usage_event_id: "evt_#{request.idempotency_key}", accepted: true)
      end

      def track_before(_request, context)
        (context[:events] ||= []) << :before
      end

      def track_after(_request, context)
        (context[:events] ||= []) << :after
      end

      def track_around(_request, context)
        (context[:events] ||= []) << :around_in
        yield
        (context[:events] ||= []) << :around_out
      end

      def reject_zero(request, _context)
        raise ConnectRpc::Error.new(:invalid_argument, "quantity must be positive") if request.quantity.zero?
      end
    end
  end

  let(:dispatcher) { ConnectRpc::Dispatcher.new.register(Billing::V1::SERVICE_DESCRIPTOR, handler_class.new) }

  def invoke(request)
    context = ConnectRpc::Context.new
    result = dispatcher.invoke(BillingHelpers::SERVICE_NAME, "IngestUsage", request, context)
    [result, context]
  end

  it "runs before, around, and after callbacks around the action in order" do
    result, context = invoke(ingest_request)

    expect(result.success?).to be(true)
    expect(context[:events]).to eq([:before, :around_in, :action, :around_out, :after])
  end

  it "halts the chain when a before callback raises" do
    result, context = invoke(ingest_request(quantity: 0))

    expect(result.success?).to be(false)
    expect(result.error.code).to eq(:invalid_argument)
    # track_before ran; reject_zero raised before the around/action/after.
    expect(context[:events]).to eq([:before])
  end

  it "respects except: so a callback can skip an action" do
    skipping = Class.new do
      include ConnectRpc::Callbacks
      before_action :track, except: [:ingest_usage]

      def ingest_usage(_request, context)
        (context[:events] ||= []) << :action
        Billing::V1::IngestUsageResponse.new(usage_event_id: "evt", accepted: true)
      end

      def track(_request, context)
        (context[:events] ||= []) << :before
      end
    end

    context = ConnectRpc::Context.new
    ConnectRpc::Dispatcher.new
      .register(Billing::V1::SERVICE_DESCRIPTOR, skipping.new)
      .invoke(BillingHelpers::SERVICE_NAME, "IngestUsage", ingest_request, context)

    expect(context[:events]).to eq([:action])
  end
end
