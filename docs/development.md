# Development

Ruby is pinned in `.mise.toml`, so [mise](https://mise.jdx.dev) users get the right interpreter and tools automatically. Otherwise use Ruby 3.4 or later.

```
bundle install
```

## Checks

```sh
bundle exec rspec             # specs
hk check --all                # rubocop, steep, actionlint, zizmor (tools pinned in .mise.toml)
bundle exec rake rbs          # regenerate and validate sig/generated from inline annotations
bundle exec rake steep        # regenerate, then type check lib with Steep
bundle exec rake conformance  # the Connect conformance suite (needs Go and buf on PATH)
```

`hk install` wires the same checks into a pre-commit hook. CI runs these checks.

## The example service

`examples/greet` is a bootable Rails app with its own bundle. The gem depends only on Action Pack, so full Rails lives in the example's `Gemfile`, not the gem's.

```sh
cd examples/greet
bundle install
bundle exec puma -b tcp://127.0.0.1:9711 config.ru
```

```console
$ curl -X POST -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer valid-token' \
    -d '{"name":"Ada","preferredLanguage":"ja"}' \
    http://127.0.0.1:9711/greet.v1.GreetService/SayHello
{"greeting":"こんにちは, Ada!"}
```

Drop the token for `401 unauthenticated`, send `{}` for `400 invalid_argument`, use `GET` for `405`, and, with the token, ask for a method the service does not declare for `404`.

`examples/greet/lib/greet_pb.rb` builds the descriptor in plain Ruby, standing in for `buf generate` output, so the example runs without a protobuf toolchain.

## Types

The library carries [rbs-inline](https://github.com/soutaro/rbs-inline) annotations (`# rbs_inline: enabled`, `#:` method signatures). `rake rbs` transpiles them into `sig/generated/**/*.rbs` and runs `rbs validate`. Commit the regenerated files: CI fails when `sig/generated` is out of date. Protobuf messages are typed `untyped`; in an application their `.rbs` usually comes from buf's `rbs` plugin.

`rake steep` checks `lib` against those signatures. Dependency signatures come from [gem_rbs_collection](https://github.com/ruby/gem_rbs_collection); run `bundle exec rbs collection install` once to populate `.gem_rbs_collection` from `rbs_collection.lock.yaml`. The collection's `actionpack` and `google-protobuf` signatures lag the versions this gem builds against, and much of that surface is `untyped`, so Steep checks the library's own logic rather than its use of Rails.

`ConnectRpcRails::Controller` is a mix-in, so `sig/manual/controller_self.rbs` declares what it is mixed into (`ActionController::API`) and the class-level accessors it installs, which RBS cannot infer from the module body.

## Conformance

The official [connectrpc/conformance](https://github.com/connectrpc/conformance) suite runs from [`conformance/`](../conformance/), scoped to the Connect protocol and unary RPCs. See [conformance/README.md](../conformance/README.md) for prerequisites and how to trace a single exchange.

## Releasing

Tags drive the release. `.github/workflows/release.yml` runs on `v*` tags, reruns the full test workflow as a gate, creates a draft GitHub release, and publishes the gem to RubyGems through OIDC trusted publishing. No API key is stored.

1. Bump `ConnectRpcRails::VERSION` and retitle the `## Unreleased` heading in `CHANGELOG.md` to `## <version> (<YYYY-MM-DD>)`. Merge that as its own pull request.
2. `git tag v<version> && git push origin v<version>`
3. Once the workflow finishes, review the draft release and publish it.
