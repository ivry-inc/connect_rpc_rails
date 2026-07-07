# frozen_string_literal: true
# rbs_inline: enabled

require "action_controller"
require "timeout"

# Connect's binary content-type, so `request.format` (and thus the instrumentation
# payload / request log) reports :proto instead of defaulting to :html.
Mime::Type.register("application/proto", :proto) unless Mime[:proto]

module ConnectRpc
  # Connect unary transport as an ActionController::API mix-in.
  #
  # Include this in an `ActionController::API` subclass and call `connect_service`:
  # it generates one Rails *action* per RPC method, so every call flows through the
  # normal controller lifecycle. That is the whole point — `process_action.action_controller`
  # fires, so the entire Rails observability ecosystem (Datadog resource naming,
  # Sentry transactions, lograge, the "Completed 200 in Xms" request log) lights up
  # for free. The handler stays a plain Ruby object holding domain logic; the
  # generated action is a thin adapter: decode the Connect body, run the interceptor
  # chain into the handler, encode the reply. Errors become Connect wire errors in
  # one place (`rescue_from`), the deadline is one `around_action`.
  #
  #   class BillingController < ActionController::API
  #     include ConnectRpc::Controller
  #     connect_service Billing::V1::SERVICE_DESCRIPTOR,
  #       handler: Billing::V1::BillingHandler.new,
  #       interceptors: [Billing::V1::AuthInterceptor.new(&VERIFIER)]
  #   end
  #
  # Routes are 1 RPC = 1 action (see ConnectRpc::Routing), so an unknown method is a
  # plain Rails 404 and a non-POST is a routing failure — the controller never sees them.
  module Controller
    # Raised inside Timeout so it can't be confused with an unrelated Timeout::Error.
    class DeadlineExceeded < StandardError; end
    private_constant :DeadlineExceeded

    #: (untyped) -> void
    def self.included(base)
      base.extend(ClassMethods)
      base.rescue_from(Error, with: :render_connect_error)
      base.around_action(:enforce_connect_deadline)
    end

    module ClassMethods
      attr_accessor :connect_registration #: ServiceRegistration
      attr_accessor :connect_interceptors #: Array[Interceptor]

      attr_accessor :connect_rpcs #: Hash[String, untyped]

      #: (untyped descriptor, handler: untyped, ?interceptors: Array[Interceptor]) -> void
      def connect_service(descriptor, handler:, interceptors: [])
        self.connect_registration = ServiceRegistration.new(descriptor, handler)
        self.connect_interceptors = interceptors
        self.connect_rpcs = {}

        descriptor.each do |method|
          rpc = connect_registration.rpc(method.name)
          connect_rpcs[rpc.handler_method] = rpc
          define_method(rpc.handler_method) { dispatch_connect_rpc(rpc) }
        end
      end
    end

    # Connect actions decode the body themselves and never read `params`, so skip
    # Rails' lazy body param parsing: it would deserialize a JSON body a second time
    # (instrumentation reads filtered_parameters) and leak request payloads into
    # logs. Query params still parse; instrumentation is otherwise unaffected.
    # Runs before instrumentation reads the params, so it decodes the Connect body
    # here (exactly once) and reuses it two ways: the typed message drives the action,
    # and its hash form populates `request_parameters` — so the standard Rails request
    # log, `config.filter_parameters`, and APM see the request without Rails parsing
    # the body a second time. Also reports the wire format for logs/instrumentation
    # (via the formats header rather than `request.format=`, which would inject a
    # :format key into params).
    def process_action(*)
      request.request_parameters = connect_request_params
      format = request.content_type.to_s.start_with?("application/proto") ? :proto : :json
      request.set_header("action_dispatch.request.formats", [Mime[format]])
      super
    end

    private def connect_request_params
      rpc = self.class.connect_rpcs[action_name]
      codec = Codec.for_content_type(request.content_type)
      return {} unless request.post? && rpc && codec

      @connect_request_message = codec.decode(rpc.input_class, request.body.read)
      @connect_request_message.to_h
    rescue Google::Protobuf::ParseError => e
      # Defer a malformed body to the action, so it flows through instrumentation and
      # the normal error path instead of aborting before the request is even logged.
      @connect_decode_error = e
      {}
    end

    private def dispatch_connect_rpc(rpc)
      @connect_full_method = "#{self.class.connect_registration.service_name}/#{rpc.name}"
      # A Connect RPC is POST-only; other verbs are a 405, per the protocol. (Routes
      # match all verbs so the wrong-verb case reaches here rather than 404-ing.)
      return render(plain: "method not allowed", status: 405) unless request.post?

      codec = Codec.for_content_type(request.content_type)
      return render(plain: "unsupported media type", status: 415) unless codec

      reject_unsupported_encoding
      raise @connect_decode_error if @connect_decode_error

      message = run_connect_chain(rpc, @connect_request_message, @connect_context)

      apply_connect_metadata(@connect_context)
      render body: codec.encode(message)
      # Connect wants a bare `application/proto` / `application/json`; drop the
      # charset ActionController appends (conformance rejects it on proto).
      response.headers["content-type"] = codec.content_type
    end

    # Connect rejects unsupported request compression with `unimplemented`, advertising
    # what it can accept.
    private def reject_unsupported_encoding
      encoding = request.headers["Content-Encoding"]
      return if encoding.nil? || ["", "identity"].include?(encoding)

      response.headers["accept-encoding"] = "identity"
      raise Error.new(:unimplemented, "unsupported content-encoding: #{encoding}")
    end

    # Same chain shape as the old standalone dispatcher: interceptors wrap a terminal
    # that calls the PORO handler, so the interceptor code is unchanged.
    private def run_connect_chain(rpc, request_message, context)
      handler = self.class.connect_registration.handler
      terminal = ->(req, ctx) { handler.public_send(rpc.handler_method, req, ctx) }
      chain = self.class.connect_interceptors.reverse.reduce(terminal) do |nxt, interceptor|
        ->(req, ctx) { interceptor.call(req, ctx, nxt) }
      end
      chain.call(request_message, context)
    end

    # Builds the Context from headers and enforces connect-timeout-ms. Runs as an
    # around_action so the whole action (decode + interceptors + handler) is under
    # the deadline; the Error it raises is rendered by rescue_from.
    private def enforce_connect_deadline(&block)
      @connect_context = build_connect_context
      deadline = @connect_context.deadline
      return yield unless deadline

      remaining = deadline - Time.now
      raise Error.new(:deadline_exceeded, "deadline exceeded") if remaining <= 0

      begin
        Timeout.timeout(remaining, DeadlineExceeded, &block)
      rescue DeadlineExceeded
        raise Error.new(:deadline_exceeded, "deadline exceeded")
      end
    end

    private def build_connect_context
      metadata = {} #: Hash[String, String]
      request.headers.each do |key, value|
        next unless key.is_a?(String) && key.start_with?("HTTP_")

        metadata[key[5..].downcase.tr("_", "-")] = value
      end

      timeout_ms = metadata["connect-timeout-ms"]&.to_i
      deadline = timeout_ms ? Time.now + (timeout_ms / 1000.0) : nil
      Context.new(metadata:, deadline:, timeout_ms:)
    end

    private def apply_connect_metadata(context)
      context.response_headers.each { |name, values| response.headers[name] = values.join("\n") }
      context.response_trailers.each { |name, values| response.headers["trailer-#{name}"] = values.join("\n") }
    end

    private def render_connect_error(error)
      # Leading/trailing metadata the handler set before raising must still be sent.
      apply_connect_metadata(@connect_context) if @connect_context
      render json: error.to_wire, status: error.http_status
    end

    # The official hook for enriching the process_action.action_controller payload
    # (same mechanism lograge/Datadog custom fields use). Adds the fully-qualified
    # Connect method so a trace/log resource can read "pkg.Service/Method".
    private def append_info_to_payload(payload)
      super
      payload[:connect_method] = @connect_full_method if @connect_full_method
    end
  end
end
