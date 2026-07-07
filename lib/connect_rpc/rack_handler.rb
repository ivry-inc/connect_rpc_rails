# frozen_string_literal: true
# rbs_inline: enabled

require 'json'
require 'rack'

module ConnectRpc
  # Connect unary protocol over Rack: POST /<pkg.Service>/<Method>, body is the
  # bare message encoded per Content-Type (application/json or application/proto).
  # A thin adapter — it resolves + decodes the request, then renders the Result
  # from Dispatcher#invoke. It has no error rescue: protocol errors arrive as a
  # failure Result, and unexpected exceptions propagate to the host's middleware.
  class RackHandler
    # @rbs!
    #   type rack_response = [Integer, Hash[String, String], Array[String]]

    #: (Dispatcher) -> void
    def initialize(dispatcher)
      @dispatcher = dispatcher
    end

    #: (Hash[String, untyped]) -> rack_response
    def call(env)
      request = Rack::Request.new(env)
      # Malformed/unsupported requests map to HTTP status alone (no Connect error
      # body); the client infers the code from the status, per the protocol.
      return status_response(405) unless request.post?

      service_name, method_name = parse_path(request.path_info)
      registration = @dispatcher.registration(service_name) if service_name
      rpc = registration.rpc(method_name) if registration && method_name
      return status_response(404) unless rpc

      codec = Codec.for_content_type(request.content_type)
      return status_response(415) unless codec

      encoding = request.get_header('HTTP_CONTENT_ENCODING')
      return unsupported_encoding_response(encoding) if encoding && !['', 'identity'].include?(encoding)

      request_message = codec.decode(rpc.input_class, request.body.read)
      context = build_context(env)
      result = @dispatcher.invoke(service_name, method_name, request_message, context)
      return error_response(result.error, context) unless result.success?

      headers = {'content-type' => codec.content_type}
      apply_response_metadata(headers, context)
      [200, headers, [codec.encode(result.message)]]
    end

    # Service names contain dots, not slashes, so a Connect path is exactly
    # two segments. Taking the last two tolerates a mount prefix.
    #: (String) -> [String?, String?]
    private def parse_path(path_info)
      segments = path_info.split('/').reject(&:empty?)
      return [nil, nil] if segments.size < 2

      segments.last(2)
    end

    #: (Hash[String, untyped]) -> Context
    private def build_context(env)
      metadata = {} #: Hash[String, String]
      env.each do |key, value|
        next unless key.start_with?('HTTP_')

        metadata[key[5..].downcase.tr('_', '-')] = value
      end

      timeout_ms = metadata['connect-timeout-ms']&.to_i
      deadline = timeout_ms ? Time.now + (timeout_ms / 1000.0) : nil
      Context.new(metadata:, deadline:, timeout_ms:)
    end

    # A bare HTTP status with a non-JSON body, so the Connect client synthesises
    # the code from the status rather than parsing a Connect error frame.
    #: (Integer) -> rack_response
    private def status_response(status)
      [status, {'content-type' => 'text/plain; charset=utf-8'}, [Rack::Utils::HTTP_STATUS_CODES.fetch(status)]]
    end

    # Unsupported request compression is a Connect `unimplemented` error that also
    # advertises what the server can accept.
    #: (String) -> rack_response
    private def unsupported_encoding_response(encoding)
      status, headers, body = error_response(Error.new(:unimplemented, "unsupported content-encoding: #{encoding}"))
      headers['accept-encoding'] = 'identity'
      [status, headers, body]
    end

    #: (Error, ?Context?) -> rack_response
    private def error_response(error, context = nil)
      headers = {'content-type' => 'application/json'}
      apply_response_metadata(headers, context) if context
      [error.http_status, headers, [JSON.generate(error.to_wire)]]
    end

    # Leading metadata are plain headers; trailing metadata use a `trailer-` prefix
    # (Connect's unary convention). Multiple values are newline-joined per Rack 3.
    #: (Hash[String, String], Context) -> void
    private def apply_response_metadata(headers, context)
      context.response_headers.each { |name, values| headers[name] = values.join("\n") }
      context.response_trailers.each { |name, values| headers["trailer-#{name}"] = values.join("\n") }
    end
  end
end
