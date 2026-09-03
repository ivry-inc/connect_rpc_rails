# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "json"
require "action_dispatch/middleware/exception_wrapper"

module ConnectRpcRails
  # Wraps a Rails `config.exceptions_app` so an exception escaping a Connect call — one
  # raised before dispatch, which no controller `rescue_from` ever sees — is still answered
  # in the protocol's error shape.
  #
  #   config.exceptions_app = ConnectRpcRails::ExceptionsApp.new(MyExceptions.new(Rails.public_path))
  #
  # A Connect request is recognized by `connect-protocol-version`, which the protocol
  # requires on every unary call; anything else reaches the wrapped app untouched.
  class ExceptionsApp
    # `connect-protocol-version`, as Rack names it in the env.
    PROTOCOL_VERSION_HEADER = "HTTP_CONNECT_PROTOCOL_VERSION"

    #: (untyped app) -> void
    def initialize(app)
      @app = app
    end

    #: (Hash[String, untyped]) -> [Integer, Hash[String, String], Array[String]]
    def call(env)
      exception = env["action_dispatch.exception"]
      return @app.call(env) unless exception && env[PROTOCOL_VERSION_HEADER]

      render_connect_error(connect_error_for(exception, env))
    end

    # The error to send for an escaped exception. The message is the status's own text,
    # never the exception's, which can quote internals. Override in a subclass to add
    # details every error should carry.
    #: (Exception, Hash[String, untyped]) -> Error
    private def connect_error_for(exception, env)
      return exception if exception.is_a?(Error)

      # Read the way ActionDispatch::PublicExceptions reads it, so `rescue_responses` stays
      # the one place the app classifies an exception.
      status = ActionDispatch::ExceptionWrapper.new(
        env["action_dispatch.backtrace_cleaner"], exception
      ).status_code
      Error.new(Error.code_for_http_status(status), Rack::Utils::HTTP_STATUS_CODES.fetch(status, "error"))
    end

    # A unary Connect error is a JSON body whatever the request's codec was, per the
    # protocol.
    #: (Error) -> [Integer, Hash[String, String], Array[String]]
    private def render_connect_error(error)
      body = JSON.generate(error.to_wire)

      [
        error.http_status,
        {"content-type" => Codec::Json::CONTENT_TYPE, "content-length" => body.bytesize.to_s},
        [body],
      ]
    end
  end
end
