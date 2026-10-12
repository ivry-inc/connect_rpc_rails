# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "uri"

module ConnectRpcRails
  # The query string of a Connect unary GET, which carries the codec, compression and message
  # a POST sends as headers and body:
  #
  #   GET /greet.v1.GreetService/SayHello?connect=v1&encoding=json&message=%7B%22name%22%3A%22Ada%22%7D
  class GetQuery
    # The parameters the protocol defines. Any other parameter is allowed and ignored.
    PARAMS = ["connect", "base64", "compression", "encoding", "message"].freeze #: Array[String]

    # The `connect` value Connect clients send, the GET counterpart of `connect-protocol-version: 1`.
    PROTOCOL_VERSION = "v1" #: String

    # RFC 4648 §5 base64, unpadded or padded to a whole quantum.
    URL_SAFE_BASE64 = /\A(?:[A-Za-z0-9_-]{4})*(?:[A-Za-z0-9_-]{2}(?:==)?|[A-Za-z0-9_-]{3}=?)?\z/ #: Regexp

    # Raised when the `message` parameter is missing or is not the base64 it claims to be.
    class InvalidMessage < StandardError; end

    # Each parameter takes its first value, and a pair with invalid percent-encoding is
    # dropped, as connect-go reads a query.
    #: (String) -> GetQuery
    def self.parse(query_string)
      params = {} #: Hash[String, String]
      query_string.split("&").each do |pair|
        raw_key, raw_value = pair.split("=", 2)
        key = URI.decode_www_form_component(raw_key.to_s)
        next if !PARAMS.include?(key) || params.key?(key)

        params[key] = URI.decode_www_form_component(raw_value.to_s)
      rescue ArgumentError
        next
      end
      new(params)
    end

    #: (Hash[String, String]) -> void
    def initialize(params)
      @params = params
    end

    #: () -> String?
    def connect = @params["connect"]

    #: () -> String?
    def encoding = @params["encoding"]

    #: () -> String?
    def compression = @params["compression"]

    # The `message` parameter's bytes. With `base64=1` it is URL-safe base64, padded or not;
    # any other `base64` value is ignored, per the protocol.
    #: () -> String
    def message
      message = @params["message"] || raise(InvalidMessage, "missing message query parameter")
      return message unless @params["base64"] == "1"
      raise InvalidMessage, "invalid message query parameter" unless URL_SAFE_BASE64.match?(message)

      standard = message.delete("=").tr("-_", "+/")
      (standard + "=" * (-standard.length % 4)).unpack1("m").to_s
    end
  end
end
