# Changelog

## Unreleased

- `ConnectRpcRails::MessageValidatable` (`require "connect_rpc_rails/protovalidate"`) checks a
  request against its message's `buf.validate` rules before the RPC runs, answering a
  violation as `invalid_argument` with a `google.rpc.BadRequest` whose field paths follow the
  request's encoding. A violation raises `MessageValidatable::ViolationError`, and
  `connect_error_for_violation` builds the Connect error it is answered with.

## 0.1.0 (2026-09-25)

- Initial release: Connect unary RPCs served as ordinary `ActionController::API` actions,
  with the routes DSL, the Connect error shape (including for exceptions that escape to
  `config.exceptions_app`), and RBS signatures.
