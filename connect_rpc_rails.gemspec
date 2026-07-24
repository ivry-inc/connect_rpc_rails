# frozen_string_literal: true

require_relative "lib/connect_rpc_rails/version"

Gem::Specification.new do |spec|
  spec.name = "connect_rpc_rails"
  spec.version = ConnectRpcRails::VERSION
  spec.authors = ["IVRy Inc."]
  spec.summary = "Minimal Connect RPC (unary) server for Rails, built on ActionController::API."
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {"allowed_push_host" => "https://example.invalid"}

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 7.0"
  spec.add_dependency "google-protobuf", "~> 4.26"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rbs", "~> 4.0"
  spec.add_development_dependency "rbs-inline", "~> 0.14"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "rubocop-shopify", "~> 2.0"
end
