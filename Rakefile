# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Regenerate inline RBS signatures under sig/generated"
task :rbs do
  sh "rbs-inline --output=sig/generated lib"
  sh "rbs -I sig/generated validate"
end

task default: :spec
