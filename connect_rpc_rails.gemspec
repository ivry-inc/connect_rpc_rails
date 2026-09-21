# frozen_string_literal: true

require_relative "lib/connect_rpc_rails/version"

Gem::Specification.new do |spec|
  spec.name = "connect_rpc_rails"
  spec.version = ConnectRpcRails::VERSION
  spec.authors = ["IVRy Inc."]
  spec.email = ["arch@ivry.jp"]
  spec.summary = "Minimal Connect RPC (unary) server for Rails, built on ActionController::API."
  spec.description = "Serves Connect unary RPCs as ordinary Rails controller actions, so every " \
    "call flows through the normal ActionController::API lifecycle and the Rails observability " \
    "stack works with no extra wiring."
  spec.homepage = "https://github.com/ivry-inc/connect_rpc_rails"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 7.0"
  spec.add_dependency "google-protobuf", "~> 4.26"

  spec.add_development_dependency "puma", "~> 8.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rbs", "~> 4.0"
  spec.add_development_dependency "rbs-inline", "~> 0.14"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "rubocop-shopify", "~> 2.0"
  spec.add_development_dependency "steep", "~> 2.0"
end
