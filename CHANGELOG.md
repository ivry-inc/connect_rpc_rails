# Changelog

## 0.2.0 (2026-10-14)

- Connect GET: a unary RPC whose `.proto` sets `idempotency_level = NO_SIDE_EFFECTS` is also
  served over GET, with the request in the query string, as connect-es sends with `useHttpGet`
  and connect-go with `WithHTTPGet`. A GET to any other RPC is a 405, and every 405 names the
  allowed verbs in `Allow`. `ConnectRpcRails::ExceptionsApp` answers a GET carrying
  `connect=v1` in the Connect error shape. `ServiceRegistration::Rpc` gains `idempotency_level`
  and `streaming`.
- The `unimplemented` answer to request compression names the supported encodings in its
  message: `unsupported content-encoding "gzip": supported encodings are identity`.
- `ConnectRpcRails::MessageValidatable` (`require "connect_rpc_rails/protovalidate"`) checks a
  request against its message's `buf.validate` rules before the RPC runs, answering a
  violation as `invalid_argument` with a `google.rpc.BadRequest` whose field paths follow the
  request's encoding. A violation raises `MessageValidatable::ViolationError`, and
  `connect_error_for_violation` builds the Connect error it is answered with.

## 0.1.0 (2026-09-25)

- Initial release: Connect unary RPCs served as ordinary `ActionController::API` actions,
  with the routes DSL, the Connect error shape (including for exceptions that escape to
  `config.exceptions_app`), and RBS signatures.
