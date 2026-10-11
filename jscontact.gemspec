# frozen_string_literal: true

require_relative "lib/jscontact/version"

Gem::Specification.new do |spec|
  spec.name = "jscontact"
  spec.version = Jscontact::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Read, validate, and convert JSContact contact cards"
  spec.description = "JSContact 1.0 and 2.0 models, validation, localization patches, and optional vCard 4.0 conversion."
  spec.homepage = "https://github.com/ydah/jscontact"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "sig/**/*.rbs", "data/*.yml", "README.md", "LICENSE.txt", "CHANGELOG.md", "SECURITY.md"] }
  spec.require_paths = ["lib"]
  spec.add_dependency "json", ">= 2.19.4", "< 4"
  spec.add_dependency "tzinfo", ">= 2.0", "< 3"
end
