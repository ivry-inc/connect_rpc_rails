# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "action_controller"
require "action_dispatch/middleware/exception_wrapper"
require "timeout"

module ConnectRpcRails
  # Connect unary transport as an ActionController::API mix-in.
  #
  # Include this in an `ActionController::API` subclass and call `connect_service`:
  # each RPC in the descriptor is one Rails *action* on that controller, so every call
  # flows through the normal controller lifecycle. That is the whole point —
  # `process_action.action_controller` fires, so the entire Rails observability
  # ecosystem (Datadog resource naming, Sentry transactions, lograge, the
  # "Completed 200 in Xms" request log) lights up for free. The transport wraps the
  # action rather than generating it: decode the Connect body, call the action, encode the
  # reply. Errors become Connect wire errors in one place (`rescue_from`), the deadline is
  # one `around_action`.
  #
  #   class GreetController < ActionController::API
  #     include ConnectRpcRails::Controller
  #     include BearerAuthentication
  #     connect_service "greet.v1.GreetService"
  #
  #     def say_hello
  #       SayHelloResponse.new(greeting: "Hello, #{connect_request.name}!")
  #     end
  #   end
  #
  # An action takes no arguments, like every other Rails action: the decoded request is
  # `connect_request`, read the way `params` is read in an HTTP controller. It is an
  # ordinary instance method, so it gets the per-request instance Rails already builds for
  # every action — nothing holding request state outlives the request. There is
  # deliberately no handler object registered on the controller class: that one instance
  # would be shared by every request in the process.
  #
  # A Connect call is an HTTP request, so cross-cutting concerns are Rails callbacks and
  # nothing else: `before_action` for auth (writing an ivar, not a context bag),
  # `around_action` to wrap a call, `rescue_from` (or `map_connect_errors`) to turn a
  # domain exception into a Connect code. The decode happens before the callbacks run, so
  # a `before_action` can already read `connect_request`. There is no interceptor layer:
  # callbacks do the same job with `only:`/`except:`, inheritance and `skip_*` on top.
  #
  # Exceptions the host app already classifies need no mapping at all: Rails keeps that
  # classification in `config.action_dispatch.rescue_responses`, which every railtie and
  # gem registers into (`ActiveRecord::RecordNotFound` is `:not_found` there), so including
  # this module installs a Connect code for each of those entries. `map_connect_errors` is
  # for the ones Rails doesn't know about, and overrides these.
  #
  # Routes are 1 RPC = 1 action, drawn per service from the descriptor (see
  # ConnectRpcRails::Routing). A declared RPC the controller doesn't implement is answered
  # `unimplemented` by #action_missing; a method the descriptor never declared lands on the
  # routes' catch-all, #connect_unknown_method, and is a 404. Routes match every verb, so a
  # wrong-verb request does reach the controller and becomes a Connect-correct 405.
  # @rbs module-self ActionController::API
  # @rbs module-self _ConnectControllerSelf
  module Controller
    # The action and path parameter the routes DSL points its per-service catch-all at.
    UNKNOWN_METHOD_ACTION = "connect_unknown_method"
    UNKNOWN_METHOD_PARAM = "connect_method"

    # The one `rescue_responses` entry that doesn't become a Connect error: #action_missing
    # raises ActionNotFound for a name that isn't an RPC, which means the app routed
    # something to an action this controller doesn't have. That is a misconfiguration for
    # the host's error handling to surface, not a result to hand a caller.
    RESCUE_RESPONSE_EXCLUSIONS = ["AbstractController::ActionNotFound"].freeze

    # Raised inside Timeout so it can't be confused with an unrelated Timeout::Error.
    class DeadlineExceeded < StandardError; end
    private_constant :DeadlineExceeded

    #: (untyped) -> void
    def self.included(base)
      base.extend(ClassMethods)
      no_mapping = {} #: Hash[Class, Symbol]
      base.class_attribute(:connect_error_mapping, default: no_mapping)
      # Registered first, so both the Error handler and anything `map_connect_errors` adds
      # later take precedence: Rails picks the most recently registered matching handler.
      install_rescue_response_defaults(base)
      base.rescue_from(Error, with: :render_connect_error)
      base.around_action(:enforce_connect_deadline)
      base.prepend_before_action(:validate_connect_request)
    end

    # Gives every exception Rails already assigns an HTTP status a Connect code, so an app
    # doesn't restate a mapping the framework ships. Registered by class *name*, which is
    # both what `rescue_responses` is keyed by and what keeps this from loading the classes
    # (`rescue_from` resolves the name when it has to rescue something).
    #
    # This reads `rescue_responses` once, when the controller is loaded — in a Rails app
    # that is after the initializers have merged the app's own entries in.
    #: (untyped) -> void
    def self.install_rescue_response_defaults(base)
      ActionDispatch::ExceptionWrapper.rescue_responses.each_key do |class_name|
        next if RESCUE_RESPONSE_EXCLUSIONS.include?(class_name)

        base.rescue_from(class_name, with: :render_rescue_response_error)
      end
    end

    # @rbs module-self Module
    # @rbs module-self _ConnectControllerClass
    module ClassMethods
      attr_accessor :connect_registration #: ServiceRegistration

      attr_accessor :connect_rpcs #: Hash[String, untyped]

      # Declares which Connect service this controller serves, named as the `.proto` names
      # it: `connect_service "greet.v1.GreetService"`. The string is looked up in the
      # descriptor pool, so it greps straight to the protobuf definition (and back).
      #: (String | untyped service) -> void
      def connect_service(service)
        self.connect_registration = ServiceRegistration.new(service)
        rpcs = {} #: Hash[String, untyped]
        connect_registration.rpcs.each { |rpc| rpcs[rpc.action] = rpc }
        self.connect_rpcs = rpcs
      end

      # Turns domain exceptions into Connect errors for every RPC on the controller:
      #
      #   map_connect_errors MyDomain::Invalid => :invalid_argument,
      #     MyDomain::QuotaReached => :resource_exhausted
      #
      # Only for exceptions Rails doesn't already classify — anything in
      # `config.action_dispatch.rescue_responses` has a code without being named here (see
      # .install_rescue_response_defaults) — or to override the code one of those got.
      #
      # This is `rescue_from` with the conversion filled in — each class gets its own
      # handler, so nothing is blanket-rescued and an unmapped exception still propagates
      # to the host's error middleware. The handler renders rather than re-raising because
      # Rails calls one `rescue_from` handler per exception: an Error raised inside a
      # handler would escape instead of reaching the one that renders the wire error.
      #: (Hash[Class, Symbol]) -> void
      def map_connect_errors(mapping)
        self.connect_error_mapping = connect_error_mapping.merge(mapping)
        mapping.each_key { |klass| rescue_from(klass, with: :render_mapped_connect_error) }
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

    # The RPC method is the controller's own method, so the transport wraps dispatch
    # instead of defining the action body: `send_action` is
    # Rails' documented seam for "change how action methods are called".
    private def send_action(action, *args)
      rpc = self.class.connect_rpcs[action]
      return super unless rpc

      dispatch_connect_rpc(rpc)
    end

    # The service-prefix catch-all the routes DSL draws after the RPC routes. Every method
    # the descriptor declares has its own route, so reaching here means this one isn't part
    # of the service's contract at all: a 404 whatever the verb — rendered rather than
    # raised as a RoutingError, so it doesn't depend on the host having Rails' exception
    # middleware in the stack. No body is decoded for it either.
    def connect_unknown_method
      @connect_full_method = "#{self.class.connect_registration.service_name}/#{connect_method_param}"
      render(plain: "not found", status: 404)
    end

    # Every RPC the descriptor declares is routed, whether or not this controller has the
    # method, because what the service serves is the descriptor's business and not the
    # router's. A routed RPC with no action is exactly the case Connect answers
    # `unimplemented`, and Rails' own hook for "this action doesn't exist" is where that is
    # answered. An action name that isn't an RPC at all raises what Rails would have raised
    # had this hook not been defined.
    private def action_missing(name)
      unless self.class.connect_rpcs[name]
        raise AbstractController::ActionNotFound.new(
          "The action '#{name}' could not be found for #{self.class.name}",
          self,
          name,
        )
      end

      raise Error.new(:unimplemented, "#{@connect_full_method} is not implemented")
    end

    # Transport preconditions, prepended so they run ahead of any application callback: a
    # wrong verb or a body nothing can read is answered the way the protocol says instead
    # of being handed to auth (or anything else the controller declared) first. Halting
    # with `render` is Rails' own way to stop a callback chain.
    private def validate_connect_request
      rpc = self.class.connect_rpcs[action_name]
      # The catch-all and any non-RPC action have nothing to validate: they answer for
      # themselves (see #connect_unknown_method).
      return unless rpc

      @connect_full_method = "#{self.class.connect_registration.service_name}/#{rpc.name}"

      # A Connect RPC is POST-only; other verbs are a 405, per the protocol. (Routes
      # match all verbs so the wrong-verb case reaches here rather than 404-ing.)
      return render(plain: "method not allowed", status: 405) unless request.post?
      return render(plain: "unsupported media type", status: 415) unless Codec.for_content_type(request.content_type)

      reject_unsupported_encoding
      # A raw ParseError isn't a ConnectRpcRails::Error, so it would escape rescue_from and
      # become a 500. A malformed body is client input: surface it as invalid_argument.
      # (Don't echo the decoder message — it can quote payload fragments back.)
      raise Error.new(:invalid_argument, "invalid request body") if @connect_decode_error
    end

    #: () -> String
    private def connect_method_param
      params[UNKNOWN_METHOD_PARAM].to_s
    end

    private def connect_request_params
      rpc = self.class.connect_rpcs[action_name]
      codec = Codec.for_content_type(request.content_type)
      return {} unless request.post? && rpc && codec

      @connect_request = codec.decode(rpc.input_class, request.body.read)
      @connect_request.to_h
    rescue Google::Protobuf::ParseError => e
      # Defer a malformed body to the action, so it flows through instrumentation and
      # the normal error path instead of aborting before the request is even logged.
      @connect_decode_error = e
      {}
    end

    # The transport preconditions have all passed by the time this runs (see
    # #validate_connect_request), so this is the wire round-trip and nothing else. The RPC
    # runs on this controller instance — the one Rails built for this request — and takes
    # no arguments, like any other action. Only implemented methods are routed (the routes
    # DSL checks that at boot), so there is no missing-method case.
    private def dispatch_connect_rpc(rpc)
      message = public_send(rpc.action)

      apply_connect_trailers
      render body: connect_codec.encode(message)
      # Connect wants a bare `application/proto` / `application/json`; drop the
      # charset ActionController appends (conformance rejects it on proto).
      response.headers["content-type"] = connect_codec.content_type
    end

    # The codec for this call's content-type. Never missing once the action runs:
    # #validate_connect_request answers a content-type no codec handles with a 415.
    #: () -> Codec::_Codec
    private def connect_codec
      Codec.for_content_type(request.content_type) ||
        raise(Error.new(:internal, "no codec for #{request.content_type}"))
    end

    # Connect rejects unsupported request compression with `unimplemented`, advertising
    # what it can accept.
    private def reject_unsupported_encoding
      encoding = request.headers["Content-Encoding"]
      return if encoding.nil? || ["", "identity"].include?(encoding)

      response.headers["accept-encoding"] = "identity"
      raise Error.new(:unimplemented, "unsupported content-encoding: #{encoding}")
    end

    # The decoded request message, for the action to read the way an HTTP action reads
    # `params`. Assigned during decode, so callbacks see it too.
    #: () -> untyped
    private def connect_request
      @connect_request
    end

    # Request metadata: the request's HTTP headers, downcased and dasherized, which is
    # what Connect metadata is on the wire. Response metadata needs no helper — leading
    # metadata is `response.headers`.
    #: () -> Hash[String, String]
    private def connect_metadata
      @connect_metadata ||= begin
        metadata = {} #: Hash[String, String]
        request.headers.each do |key, value|
          next unless key.is_a?(String) && key.start_with?("HTTP_")

          metadata[key.delete_prefix("HTTP_").downcase.tr("_", "-")] = value
        end
        metadata
      end
    end

    # Trailing metadata to send. Unary Connect puts trailers in the response as
    # `trailer-`-prefixed headers, so this collects them and #apply_connect_trailers does
    # the prefixing — a caller writes `connect_trailers["x-audit"] = ["1"]` and doesn't
    # encode the wire form itself.
    #: () -> Hash[String, Array[String]]
    private def connect_trailers
      @connect_trailers ||= {}
    end

    # Rack joins repeated headers with a newline, which is also how multi-value Connect
    # metadata is sent.
    private def apply_connect_trailers
      connect_trailers.each { |name, values| response.headers["trailer-#{name}"] = Array(values).join("\n") }
    end

    # The deadline this call must finish by, from `connect-timeout-ms`, or nil when the
    # caller sent no timeout. The library enforces it; an RPC reads it to budget its own
    # downstream calls.
    #: () -> Time?
    private def connect_deadline
      @connect_deadline
    end

    #: () -> Integer?
    private def connect_timeout_ms
      @connect_timeout_ms
    end

    # Enforces connect-timeout-ms. Runs as an around_action so the whole action (the
    # callbacks and the RPC) is under the deadline; the Error it raises is rendered by
    # rescue_from.
    #: () { (?) -> untyped } -> untyped
    private def enforce_connect_deadline(&block)
      raw_timeout = connect_metadata["connect-timeout-ms"]
      # connect-timeout-ms is up to 10 ASCII digits per the protocol. String#to_i would
      # coerce "abc" to 0 (an already-expired deadline → 504) and silently truncate
      # "10abc" to 10; a malformed value is client input, so reject it as invalid_argument.
      if raw_timeout && !/\A\d{1,10}\z/.match?(raw_timeout)
        raise Error.new(:invalid_argument, "invalid connect-timeout-ms")
      end
      return yield unless raw_timeout

      @connect_timeout_ms = Integer(raw_timeout, 10)
      @connect_deadline = Time.now + (@connect_timeout_ms / 1000.0)
      remaining = @connect_deadline - Time.now
      raise Error.new(:deadline_exceeded, "deadline exceeded") if remaining <= 0

      begin
        Timeout.timeout(remaining, DeadlineExceeded, &block)
      rescue DeadlineExceeded
        raise Error.new(:deadline_exceeded, "deadline exceeded")
      end
    end

    # The handler `map_connect_errors` installs: the mapping lives on the class, so the
    # code for the exception at hand is looked up rather than baked into a closure.
    private def render_mapped_connect_error(exception)
      _, code = self.class.connect_error_mapping.find { |klass, _| exception.is_a?(klass) }
      # Only classes in the mapping are rescued, so this can't miss; re-raise rather than
      # invent a code if it somehow does.
      raise exception unless code

      render_connect_error(Error.new(code, exception.message))
    end

    # The handler installed for every `rescue_responses` entry. The status is read off the
    # nearest ancestor the registry names, since `rescue_from` matches subclasses too and a
    # subclass isn't a key (an `ActiveRecord::RecordNotUnique` is classified as the
    # `StatementInvalid` it descends from). Read with `fetch`, because the registry answers
    # anything at all with a default of :internal_server_error — which would stop the walk
    # on the first ancestor and call every subclass a 500.
    private def render_rescue_response_error(exception)
      responses = ActionDispatch::ExceptionWrapper.rescue_responses
      status = exception.class.ancestors.lazy.filter_map { |klass| responses.fetch(klass.name, nil) }.first
      # Only registered names are rescued here, so this can't miss; re-raise rather than
      # invent a code if it somehow does.
      raise exception unless status

      code = Error.code_for_http_status(Rack::Utils.status_code(status))
      render_connect_error(Error.new(code, exception.message))
    end

    private def render_connect_error(error)
      # Trailing metadata the RPC set before raising must still be sent. Leading metadata
      # needs nothing here: it was written straight to `response.headers`, which survives
      # the raise.
      apply_connect_trailers
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
