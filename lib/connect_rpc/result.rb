# frozen_string_literal: true
# rbs_inline: enabled

module ConnectRpc
  # The outcome of Dispatcher#invoke: either a response message (success) or a
  # ConnectRpc::Error (failure). Each transport renders it — the wire transport
  # encodes an error frame, the in-process transport re-raises for the caller —
  # so a ConnectRpc::Error is turned into a result in exactly one place.
  Result = Data.define(:message, :error)

  # Reopened (rather than subclassed, per Style/DataInheritance) to add the
  # factories and predicate, which keeps them visible to rbs-inline.
  class Result
    #: (untyped) -> Result
    def self.success(message) = new(message:, error: nil)

    #: (Error) -> Result
    def self.failure(error) = new(message: nil, error:)

    #: () -> bool
    def success? = error.nil?
  end
end
