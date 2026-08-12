# frozen_string_literal: true

require_relative "lib/pluckr/version"

Gem::Specification.new do |spec|
  spec.name = "pluckr"
  spec.version = Pluckr::VERSION
  spec.authors = ["Igor Kasyanchuk"]
  spec.email = ["igorkasyanchuk@gmail.com"]

  spec.summary = "A declarative read-query layer for ActiveRecord."
  spec.description = "Pluckr lets you declare the shape of the data you need and compiles it " \
                     "into a single SQL statement, returning lightweight immutable result " \
                     "objects instead of ActiveRecord models. Works on PostgreSQL, MySQL and SQLite."
  spec.homepage = "https://github.com/igorkasyanchuk/pluckr"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
end
