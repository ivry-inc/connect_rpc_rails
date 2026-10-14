# frozen_string_literal: true

target :lib do
  signature "sig/generated", "sig/manual"
  check "lib"
  # Loaded by tapioca only, under its own Sorbet-typed API.
  ignore "lib/tapioca"

  library "base64"
  library "timeout"
end
