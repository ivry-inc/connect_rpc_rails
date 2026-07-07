# frozen_string_literal: true

module Billing
  module V1
    # Stands in for crossbar-rp bearer verification: it authenticates the Bearer
    # token and writes the resulting principal onto the context for the handler to
    # read. This is the authN edge; authZ (realm/payer scoping) belongs in the
    # handler. "principal" is just a convention on the context values bag, not a
    # library concept.
    class AuthInterceptor < ConnectRpc::Interceptor
      # verifier: a callable token -> principal (or nil). In production this is
      # Crossbar::Rp bearer/JWKS verification returning a realm-scoped Principal.
      def initialize(&verifier)
        super()
        @verifier = verifier
      end

      def call(request, context, nxt)
        header = context.metadata['authorization'].to_s
        token = header.start_with?('Bearer ') ? header.delete_prefix('Bearer ') : nil
        principal = token && @verifier.call(token)
        raise ConnectRpc::Error.new(:unauthenticated, 'missing or invalid bearer token') unless principal

        context[:principal] = principal
        nxt.call(request, context)
      end
    end
  end
end
