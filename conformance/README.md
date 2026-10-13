# Connect conformance

Runs the official [connectrpc/conformance](https://github.com/connectrpc/conformance)
suite against the library, scoped to what it implements (Connect
protocol, unary over POST and GET, no TLS/streaming — see `config.yaml`).

## Current result

```
86 passed, 0 failed
```

Every in-scope case passes, including Connect GET to the side-effect-free
`IdempotentUnary`, error details, response headers/trailers,
`connect-timeout-ms` enforcement and deadline propagation, and the HTTP-status
mapping for malformed requests (404/405/415, unsupported compression).

Out of scope (excluded via `config.yaml`, not failures):
streaming, gRPC / gRPC-Web, request compression, and TLS.

## Prerequisites (one-time)

The server-under-test runs from the bundle (Puma is a development dependency), so
`bundle install` once. Beyond that the suite needs `go` and `buf` on PATH; the rake
task installs the runner itself into `tmp/bin` and generates the protos into `gen/`
(both git-ignored).

## Run

```sh
bundle exec rake conformance
```

Exit 0 means every in-scope case passed. The runner and the protos are both pinned to
`CONFORMANCE_VERSION` in `rakelib/conformance.rake`. To inspect an exchange, point the
task at a runner invoked by hand:

```sh
tmp/bin/connectconformance --trace --mode server --conf conformance/config.yaml \
  -- bundle exec ruby conformance/server.rb
```

## Files

- `server.rb` — the server-under-test: reads a `ServerCompatRequest` on stdin,
  boots the `ConnectRpcRails::Controller` (serving `ConformanceService`) mounted through
  an `ActionDispatch` `RouteSet` on Puma, writes the port back on stdout.
- `service_implementation.rb` — `ConformanceService` implemented against the library
  (`Unary`, and `IdempotentUnary`, which the suite calls with GET; the rest of the service is
  routed and answered `unimplemented`).
- `config.yaml` — restricts the suite to the implemented surface.
