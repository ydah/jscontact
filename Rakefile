# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)
desc "Download verified reference sources and generate temporary conformance fixtures"
task :fixtures do
  require_relative "script/update_registry"
  RFCFixtures.prepare
  JSContactRegistry.prepare
end
task spec: :fixtures
task test: :spec
task default: :spec
