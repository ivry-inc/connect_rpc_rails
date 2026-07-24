# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

module ConnectRpcRails
  # Converts configured exception classes into ConnectRpcRails::Errors, so domain or
  # framework exceptions surface as protocol errors. Only the configured classes
  # are rescued (never a blanket rescue); anything unmapped propagates untouched,
  # per the let-exceptions-propagate policy.
  #
  #   ExceptionMappingInterceptor.new(
  #     ActiveRecord::RecordNotFound => :not_found,
  #     MyDomain::Invalid => :invalid_argument,
  #   )
  class ExceptionMappingInterceptor < Interceptor
    #: (Hash[Class, Symbol]) -> void
    def initialize(mapping)
      super()
      @mapping = mapping
    end

    #: (untyped, Context, ^(untyped, Context) -> untyped) -> untyped
    def call(request, context, nxt)
      nxt.call(request, context)
    rescue *@mapping.keys => e
      code = @mapping.find { |klass, _| e.is_a?(klass) }.last
      raise Error.new(code, e.message)
    end
  end
end
