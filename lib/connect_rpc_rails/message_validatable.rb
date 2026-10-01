# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require "active_support/concern"
require "google/protobuf/well_known_types"
require "protovalidate"

require "connect_rpc_rails"

module ConnectRpcRails
  # Checks a Connect request against the `buf.validate` rules of its message before the RPC
  # runs, and answers a violation the way AIP-193 describes: `invalid_argument`, with a
  # `google.rpc.BadRequest` naming each field.
  #
  #   class GreetController < ActionController::API
  #     include ConnectRpcRails::Controller
  #     include ConnectRpcRails::MessageValidatable
  #     include BearerAuthentication
  #     connect_service "greet.v1.GreetService"
  #
  #     def say_hello = ...
  #   end
  #
  # Fields are named in the caller's encoding: `preferredLanguage` for a JSON body,
  # `preferred_language` for a binary one. `google.rpc.BadRequest` is looked up in the
  # descriptor pool rather than required, because googleapis belongs to the application: it
  # generates `google/rpc/error_details.proto` alongside its own protos, or bundles
  # googleapis-common-protos-types.
  #
  # A violation raises ViolationError, which the concern rescues into the Connect error
  # #connect_error_for_violation builds. Override that method to answer differently. Opt a
  # controller out with `skip_before_action :validate_connect_message!` at its top.
  # @rbs module-self ActionController::API
  # @rbs module-self Controller
  module MessageValidatable
    extend ActiveSupport::Concern

    # Raised when `google.rpc.BadRequest` is not in the descriptor pool.
    class MissingDescriptorError < StandardError; end

    # Raised when a request breaks a rule its message declares.
    class ViolationError < StandardError
      # @return [Array<Protovalidate::Violation>]
      attr_reader :violations #: Array[untyped]

      # @return [Object] the request message the violations were found in
      attr_reader :request_message #: untyped

      #: (Array[untyped] violations, untyped request_message) -> void
      def initialize(violations, request_message)
        @violations = violations
        @request_message = request_message
        super(violations.map(&:to_s).join("; "))
      end
    end

    BAD_REQUEST = "google.rpc.BadRequest" #: String

    # AIP-193: a FieldViolation's reason is UPPER_SNAKE_CASE and at most 63 characters.
    REASON_PATTERN = /\A[A-Z][A-Z0-9_]{1,61}[A-Z0-9]\z/ #: Regexp

    # Published for a rule id that cannot be a reason, such as a CEL rule named in lowercase.
    FALLBACK_REASON = "INVALID_VALUE" #: String

    # `self` inside an ActiveSupport::Concern block is the including class, which RBS has no
    # way to name.
    # steep:ignore:start
    included do
      # Registered at include time so `skip_before_action` at the top of a controller has an
      # entry to delete. .method_added moves it behind the callbacks declared after this.
      before_action(:validate_connect_message!)
      rescue_from(ViolationError, with: :render_connect_violation)
    end

    class_methods do
      # Rails appends a re-registered callback to the end of the chain, so defining an RPC
      # moves the validation behind the authentication a controller declares above it. An
      # invalid body answered before an unauthenticated one would tell a caller what a valid
      # body looks like. No entry means the controller skipped it, and it stays skipped.
      def method_added(method_name)
        super
        return unless connect_rpcs&.key?(method_name.to_s)
        return unless _process_action_callbacks.any? { |callback| callback.filter == :validate_connect_message! }

        before_action(:validate_connect_message!)
      end
    end
    # steep:ignore:end

    # The violated field as `parts[0].part_name`, each segment resolved against the descriptor
    # so it is spelled the way the caller's encoding spells it. Empty for a message-level rule.
    #: (untyped path, untyped message_class, json_names: bool) -> String
    def self.field_path(path, message_class, json_names:)
      return "" if path.nil?

      descriptor = message_class.descriptor
      path.elements.map do |element|
        field = descriptor&.lookup(element.field_name)
        descriptor = field_message(field)
        # A segment the descriptor cannot resolve keeps the violation's spelling, rather than
        # being dropped and shifting the rest of the path.
        name = if field.nil?
          element.field_name
        else
          json_names ? field.json_name : field.name
        end
        "#{name}#{subscript(element)}"
      end.join(".")
    end

    # The message a path continues into after this field: for a map, the value's type rather
    # than the synthetic entry, because the key is the subscript and not a segment.
    #: (untyped field) -> untyped
    def self.field_message(field)
      return unless field&.type == :message

      entry = field.subtype
      return entry unless entry.options.map_entry

      value = entry.lookup("value")
      value.type == :message ? value.subtype : nil
    end

    #: (untyped element) -> String
    def self.subscript(element)
      case element.subscript
      when :index then "[#{element.index}]"
      when :bool_key then "[#{element.bool_key}]"
      when :int_key then "[#{element.int_key}]"
      when :uint_key then "[#{element.uint_key}]"
      when :string_key then "[#{element.string_key.inspect}]"
      else ""
      end
    end

    # The rule id as a reason constant: `string.min_len` becomes `STRING_MIN_LEN`.
    #: (String rule_id) -> String
    def self.reason(rule_id)
      reason = rule_id.upcase.tr(".", "_")
      REASON_PATTERN.match?(reason) ? reason : FALLBACK_REASON
    end

    # A googleapis message class, looked up in the descriptor pool.
    #: (String name) -> untyped
    def self.googleapis_class(name)
      descriptor = Google::Protobuf::DescriptorPool.generated_pool.lookup(name)
      if descriptor.nil?
        raise MissingDescriptorError,
          "#{name} is not in the descriptor pool; generate google/rpc/error_details.proto " \
            "or bundle googleapis-common-protos-types"
      end

      descriptor.msgclass
    end

    private_class_method :field_message, :subscript

    #: () -> void
    private def validate_connect_message!
      return unless self.class.connect_rpcs[action_name]

      message = connect_request
      return if message.nil?

      # protovalidate's signatures are not loaded: see rbs_collection.yaml.
      violations = Protovalidate.collect_violations(message) # steep:ignore
      return if violations.empty?

      raise ViolationError.new(violations, message)
    end

    # The Connect error a violation is answered with: `invalid_argument` with a
    # `google.rpc.BadRequest`, naming each field the way this request's encoding spells it.
    # Override to answer differently.
    #: (ViolationError error) -> Error
    private def connect_error_for_violation(error)
      bad_request = MessageValidatable.googleapis_class(BAD_REQUEST)
      field_violation = MessageValidatable.googleapis_class("#{BAD_REQUEST}.FieldViolation")
      json_names = Codec::Json == connect_codec
      field_violations = error.violations.map do |violation|
        field_violation.new(
          field: MessageValidatable.field_path(violation.field, error.request_message.class, json_names:),
          reason: MessageValidatable.reason(violation.rule_id),
          description: violation.message,
        )
      end
      detail = field_violations.map { |v| v.field.empty? ? v.description : "#{v.field}: #{v.description}" }

      Error.new(
        :invalid_argument,
        detail.join("; "),
        details: [Google::Protobuf::Any.pack(bad_request.new(field_violations:))],
      )
    end

    # Raised rather than only built, so the Connect error carries the violation as its cause for
    # whatever reports it.
    #: (ViolationError error) -> void
    private def render_connect_violation(error)
      raise connect_error_for_violation(error), cause: error
    rescue Error => connect_error
      render_connect_exception(connect_error)
    end
  end
end
