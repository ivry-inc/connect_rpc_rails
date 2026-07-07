# frozen_string_literal: true

require "action_dispatch"

# The routes map to "billing#<action>", so the resolved controller must exist.
class BillingController < ActionController::API
  include ConnectRpc::Controller
  connect_service Billing::V1::SERVICE_DESCRIPTOR, handler: Billing::V1::BillingHandler.new
end

RSpec.describe ConnectRpc::Routing do
  let(:routes) do
    ActionDispatch::Routing::RouteSet.new.tap do |set|
      set.draw do
        ConnectRpc::Routing.mount(self, Billing::V1::SERVICE_DESCRIPTOR, controller: "billing")
      end
    end
  end

  it "routes POST /<pkg.Service>/<Method> to <controller>#<underscored_method>" do
    expect(routes.recognize_path("/billing.v1.BillingService/IngestUsage", method: :post))
      .to eq(controller: "billing", action: "ingest_usage")
  end

  it "does not route an unknown method (host router returns 404)" do
    expect { routes.recognize_path("/billing.v1.BillingService/Nope", method: :post) }
      .to raise_error(ActionController::RoutingError)
  end

  it "routes a non-POST verb to the action too (the controller answers 405)" do
    expect(routes.recognize_path("/billing.v1.BillingService/IngestUsage", method: :get))
      .to eq(controller: "billing", action: "ingest_usage")
  end
end
