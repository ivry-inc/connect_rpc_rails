# frozen_string_literal: true

require_relative "lib/connect_rpc/version"

Gem::Specification.new do |spec|
  spec.name = "connect_rpc"
  spec.version = ConnectRpc::VERSION
  spec.authors = ["IVRy"]
  spec.summary = "Minimal Connect RPC (unary) server for Rack/Rails with an in-process transport."
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {"allowed_push_host" => "https://example.invalid"}

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "google-protobuf", "~> 4.26"
  spec.add_dependency "rack", ">= 3.0"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rbs", "~> 4.0"
  spec.add_development_dependency "rbs-inline", "~> 0.14"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "rubocop-shopify", "~> 2.0"
end
