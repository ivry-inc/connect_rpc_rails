# Connect conformance

Runs the official [connectrpc/conformance](https://github.com/connectrpc/conformance)
suite against the library, scoped to what the prototype implements (Connect
protocol, unary, no TLS/streaming — see `config.yaml`).

## Current result

```
86 passed, 0 failed
```

Every in-scope case passes, including error details, response headers/trailers,
`connect-timeout-ms` enforcement and deadline propagation, and the HTTP-status
mapping for malformed requests (404/405/415, unsupported compression).

Out of scope for this prototype (excluded via `config.yaml`, not failures):
streaming, gRPC / gRPC-Web, request compression, TLS, and the idempotent-GET
variant.

## Prerequisites (one-time)

Needs Go on PATH. Install the runner and buf, and generate the conformance protos:

```sh
go install connectrpc.com/conformance/cmd/connectconformance@latest
go install github.com/bufbuild/buf/cmd/buf@latest
export PATH="$PATH:$(go env GOPATH)/bin"

cd conformance
buf generate buf.build/connectrpc/conformance   # writes gen/ (git-ignored)
```

## Run

```sh
export PATH="$PATH:$(go env GOPATH)/bin"
connectconformance --mode server --conf conformance/config.yaml -- ruby conformance/server.rb
```

Exit 0 means every in-scope case passed. Add `--trace` to inspect any exchange.

## Files

- `server.rb` — the server-under-test: reads a `ServerCompatRequest` on stdin,
  boots the `ConnectRpc::Controller` (serving `ConformanceService`) mounted through
  an `ActionDispatch` `RouteSet` on Puma, writes the port back on stdout.
- `service_handler.rb` — `ConformanceService` implemented against the library
  (only `Unary`; the rest raise `unimplemented`).
- `config.yaml` — restricts the suite to the implemented surface.
