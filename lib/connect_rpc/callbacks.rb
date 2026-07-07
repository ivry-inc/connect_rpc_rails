# frozen_string_literal: true
# rbs_inline: enabled

module ConnectRpc
  # Opt-in per-handler callbacks, in the spirit of Rails' before_action. Include
  # this in a handler to run `before_action` / `around_action` / `after_action`
  # around each RPC, optionally scoped with `only:`/`except:`. Callbacks receive
  # `(request, context)`; a before/around that raises a ConnectRpc::Error rejects
  # the call (like a before_action halting the chain). No ActiveSupport dependency.
  #
  #   class BillingHandler
  #     include ConnectRpc::Callbacks
  #     before_action :authorize!, except: [:health]
  #     def ingest_usage(request, context) = ...
  #     private def authorize!(request, context) = ...
  #   end
  module Callbacks
    Callback = Data.define(:kind, :filter, :only, :except)

    #: (Module) -> void
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      #: (?Symbol?, ?only: untyped, ?except: untyped) ?{ (untyped, Context) -> void } -> void
      def before_action(method = nil, only: nil, except: nil, &block)
        rpc_callbacks << Callback.new(kind: :before, filter: method || block, only:, except:)
      end

      #: (?Symbol?, ?only: untyped, ?except: untyped) ?{ (untyped, Context) -> void } -> void
      def after_action(method = nil, only: nil, except: nil, &block)
        rpc_callbacks << Callback.new(kind: :after, filter: method || block, only:, except:)
      end

      #: (?Symbol?, ?only: untyped, ?except: untyped) ?{ (untyped, Context, ^() -> untyped) -> untyped } -> void
      def around_action(method = nil, only: nil, except: nil, &block)
        rpc_callbacks << Callback.new(kind: :around, filter: method || block, only:, except:)
      end

      #: () -> Array[Callback]
      def rpc_callbacks
        @rpc_callbacks ||= superclass.respond_to?(:rpc_callbacks) ? superclass.rpc_callbacks.dup : []
      end
    end

    # Invoked by the dispatcher. Order mirrors Rails: befores, then the arounds
    # (first-defined outermost) wrapping the action, then afters. A raised error
    # short-circuits the rest.
    #: (Symbol, untyped, Context) -> untyped
    def run_rpc_callbacks(action, request, context)
      applicable = self.class.rpc_callbacks.select { |callback| callback_applies?(callback, action) }
      applicable.each { |callback| run_callback(callback, request, context) if callback.kind == :before }

      action_call = -> { public_send(action, request, context) }
      chain = applicable.select { |callback| callback.kind == :around }.reverse.reduce(action_call) do |nxt, callback|
        -> { run_callback(callback, request, context) { nxt.call } }
      end
      result = chain.call

      applicable.each { |callback| run_callback(callback, request, context) if callback.kind == :after }
      result
    end

    private def callback_applies?(callback, action)
      action = action.to_sym
      return false if callback.only && !Array(callback.only).map(&:to_sym).include?(action)
      return false if callback.except && Array(callback.except).map(&:to_sym).include?(action)

      true
    end

    private def run_callback(callback, request, context, &continue)
      filter = callback.filter
      if filter.is_a?(Symbol)
        send(filter, request, context, &continue)
      elsif continue
        filter.call(request, context, continue)
      else
        filter.call(request, context)
      end
    end
  end
end
