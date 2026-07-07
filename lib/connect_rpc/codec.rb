# frozen_string_literal: true
# rbs_inline: enabled

module ConnectRpc
  # Encodes/decodes bare unary message bodies. Both codecs delegate to
  # google-protobuf, so serialization is not something this library implements.
  module Codec
    # @rbs!
    #   interface _Codec
    #     def decode: (untyped message_class, String bytes) -> untyped
    #     def encode: (untyped message) -> String
    #     def content_type: () -> String
    #   end

    #: (String?) -> _Codec?
    def self.for_content_type(content_type)
      case content_type&.split(';')&.first&.strip
      when Json::CONTENT_TYPE then Json
      when Proto::CONTENT_TYPE, 'application/protobuf' then Proto
      end
    end

    module Json
      CONTENT_TYPE = 'application/json' #: String

      #: (untyped, String) -> untyped
      def self.decode(message_class, bytes)
        message_class.decode_json(bytes, {ignore_unknown_fields: true})
      end

      #: (untyped) -> String
      def self.encode(message)
        message.class.encode_json(message)
      end

      #: () -> String
      def self.content_type = CONTENT_TYPE
    end

    module Proto
      CONTENT_TYPE = 'application/proto' #: String

      #: (untyped, String) -> untyped
      def self.decode(message_class, bytes)
        message_class.decode(bytes)
      end

      #: (untyped) -> String
      def self.encode(message)
        message.class.encode(message)
      end

      #: () -> String
      def self.content_type = CONTENT_TYPE
    end
  end
end
