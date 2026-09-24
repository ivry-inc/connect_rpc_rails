# frozen_string_literal: true

# Pins both the runner and the protos it generates from, so a local run and CI
# exercise the same suite. The BSR module lags the GitHub releases, so only a tag
# published in both places can be used here.
CONFORMANCE_VERSION = "v1.0.4"

desc "Run the Connect conformance suite against the library"
task :conformance do
  harness = ENV["CONNECTCONFORMANCE"] || conformance_harness(CONFORMANCE_VERSION)
  generate_conformance_protos(CONFORMANCE_VERSION)
  runner = [harness, "--mode", "server", "--conf", "conformance/config.yaml"]
  server = ["bundle", "exec", "ruby", "conformance/server.rb"]
  sh(*runner, "--", *server)
end

# Installed under tmp/, which is git-ignored and cached by CI.
def conformance_harness(version)
  path = File.expand_path("../tmp/bin/connectconformance", __dir__)
  unless File.executable?(path)
    package = "connectrpc.com/conformance/cmd/connectconformance@#{version}"
    sh({"GOBIN" => File.dirname(path)}, "go", "install", package)
  end
  path
end

def generate_conformance_protos(version)
  return if File.directory?(File.expand_path("../conformance/gen", __dir__))

  Dir.chdir("conformance") { sh "buf", "generate", "buf.build/connectrpc/conformance:#{version}" }
end
