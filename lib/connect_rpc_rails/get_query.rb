# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "base64"
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

    # The RFC 4648 §5 alphabet. Base64.urlsafe_decode64 checks the padding and the length, but
    # also takes "+" and "/" from the standard alphabet.
    URL_SAFE_BASE64 = /\A[A-Za-z0-9_-]*={0,2}\z/ #: Regexp

    # Raised when the `message` parameter is missing or is not the base64 it claims to be.
    class InvalidMessage < StandardError; end

    # Each parameter takes its first value. An invalid percent-escape is kept as written, as
    # URI.decode_www_form does, so it fails as an unknown value rather than being dropped. The
    # query is decoded as binary, because decoding as UTF-8 scrubs the bytes of an unencoded
    # binary message; values are then tagged UTF-8 without being checked.
    #: (String) -> GetQuery
    def self.parse(query_string)
      params = {} #: Hash[String, String]
      URI.decode_www_form(query_string, Encoding::BINARY).each do |key, value|
        key = key.force_encoding(Encoding::UTF_8)
        params[key] = value.force_encoding(Encoding::UTF_8) if PARAMS.include?(key) && !params.key?(key)
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

      Base64.urlsafe_decode64(message)
    rescue ArgumentError
      raise InvalidMessage, "invalid message query parameter"
    end
  end
end
