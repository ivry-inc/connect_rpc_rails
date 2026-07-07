# frozen_string_literal: true
# rbs_inline: enabled

require "timeout"

module ConnectRpc
  # The single transport-agnostic core. Every transport (Rack, in-process) calls
  # #invoke with an already-decoded request message and a Context, so the same
  # handler and interceptor chain serve both. #invoke is also the one place a
  # ConnectRpc::Error is turned into a Result — the transports never rescue.
  class Dispatcher
    # Raised inside Timeout so it can't be confused with an unrelated Timeout::Error.
    class DeadlineExceeded < StandardError; end
    private_constant :DeadlineExceeded

    #: (?interceptors: Array[Interceptor]) -> void
    def initialize(interceptors: [])
      @registrations = {} #: Hash[String, ServiceRegistration]
      @interceptors = interceptors
    end

    #: (untyped descriptor, untyped handler) -> self
    def register(descriptor, handler)
      registration = ServiceRegistration.new(descriptor, handler)
      @registrations[registration.service_name] = registration
      self
    end

    #: (String) -> ServiceRegistration?
    def registration(service_name)
      @registrations[service_name]
    end

    #: (String, String, untyped, Context) -> Result
    def invoke(service_name, method_name, request, context)
      registration = @registrations[service_name]
      raise Error.new(:unimplemented, "unknown service #{service_name}") unless registration

      rpc = registration.rpc(method_name)
      raise Error.new(:unimplemented, "unknown method #{service_name}/#{method_name}") unless rpc

      unless request.is_a?(rpc.input_class)
        raise Error.new(:invalid_argument, "expected #{rpc.input_class}, got #{request.class}")
      end

      terminal = ->(req, ctx) { invoke_handler(registration.handler, rpc.handler_method, req, ctx) }
      chain = @interceptors.reverse.reduce(terminal) do |nxt, interceptor|
        ->(req, ctx) { interceptor.call(req, ctx, nxt) }
      end
      Result.success(within_deadline(context) { chain.call(request, context) })
    rescue Error => e
      Result.failure(e)
    end

    # Runs the handler through its per-handler callbacks if it opts into them,
    # otherwise calls the RPC method directly.
    #: (untyped, String, untyped, Context) -> untyped
    private def invoke_handler(handler, method_name, request, context)
      if handler.is_a?(Callbacks)
        handler.run_rpc_callbacks(method_name, request, context)
      else
        handler.public_send(method_name, request, context)
      end
    end

    # Enforces context.deadline (from connect-timeout-ms) if set: an already-expired
    # deadline, or one that elapses while the handler runs, becomes deadline_exceeded.
    #: (Context) { () -> untyped } -> untyped
    private def within_deadline(context, &block)
      deadline = context.deadline
      return yield unless deadline

      remaining = deadline - Time.now
      raise Error.new(:deadline_exceeded, "deadline exceeded") if remaining <= 0

      Timeout.timeout(remaining, DeadlineExceeded, &block)
    rescue DeadlineExceeded
      raise Error.new(:deadline_exceeded, "deadline exceeded")
    end
  end
end
