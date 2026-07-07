# frozen_string_literal: true

module Billing
  module V1
    # Stands in for crossbar-rp bearer verification. It runs for every transport,
    # but only authenticates when no principal is present yet: a trusted in-process
    # caller seeds values[:principal] and skips the token check entirely, while a
    # wire caller is authenticated from its Bearer token. This is the authN edge;
    # authZ (realm/payer scoping) belongs in the handler. "principal" is just a
    # convention on the context values bag, not a library concept.
    class AuthInterceptor < ConnectRpc::Interceptor
      # verifier: a callable token -> principal (or nil). In production this is
      # Crossbar::Rp bearer/JWKS verification returning a realm-scoped Principal.
      def initialize(&verifier)
        super()
        @verifier = verifier
      end

      def call(request, context, nxt)
        if context[:principal].nil?
          header = context.metadata['authorization'].to_s
          token = header.start_with?('Bearer ') ? header.delete_prefix('Bearer ') : nil
          principal = token && @verifier.call(token)
          raise ConnectRpc::Error.new(:unauthenticated, 'missing or invalid bearer token') unless principal

          context[:principal] = principal
        end

        nxt.call(request, context)
      end
    end
  end
end
