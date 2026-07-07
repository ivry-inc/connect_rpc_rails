# frozen_string_literal: true
# rbs_inline: enabled

module ConnectRpc
  # In-process transport. The host application calls the exact same handler as the
  # wire transport, with no serialization: it passes an already-built request
  # message and seeds `values` (e.g. a trusted principal) straight into
  # Dispatcher#invoke. A failure Result is re-raised, the idiomatic Ruby contract.
  class InProcess
    #: (Dispatcher, String, ?values: Hash[Symbol, untyped], ?metadata: Hash[String, String]) -> void
    def initialize(dispatcher, service_name, values: {}, metadata: {})
      @dispatcher = dispatcher
      @service_name = service_name
      @values = values
      @metadata = metadata
    end

    #: (String, untyped) -> untyped
    def call(method_name, request)
      context = Context.new(metadata: @metadata, values: @values)
      result = @dispatcher.invoke(@service_name, method_name, request, context)
      result.success? ? result.message : raise(result.error)
    end
  end
end
