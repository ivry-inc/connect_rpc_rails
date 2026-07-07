# frozen_string_literal: true

# A Connect service is just an ActionController::API controller. `connect_service`
# generates one Rails action per RPC method, so every call flows through the normal
# controller lifecycle — `before_action`/`around_action` callbacks, `rescue_from`,
# and `process_action.action_controller` instrumentation all apply for free.
class GreetController < ActionController::API
  include ConnectRpc::Controller

  connect_service Greet::V1::SERVICE_DESCRIPTOR,
    handler: Greet::V1::GreetHandler.new,
    interceptors: [
      ConnectRpc::ExceptionMappingInterceptor.new(
        ActiveRecord::RecordNotFound => :not_found,
      ),
      Greet::V1::AuthInterceptor.new(&Greet::V1::TOKEN_VERIFIER),
    ]
end
