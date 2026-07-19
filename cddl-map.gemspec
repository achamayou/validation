# frozen_string_literal: true

require_relative "lib/cddl_map/version"

Gem::Specification.new do |spec|
  spec.name = "cddl-map"
  spec.version = CddlMap::VERSION
  spec.authors = ["Amaury Chamayou"]
  spec.summary = "Validate RFCXML CBOR EDN examples against mapped CDDL blocks"
  spec.description = "Extracts declared RFCXML blocks, stages CDDL modules, and delegates all CDDL and EDN semantics to cddlc."
  spec.homepage = "https://github.com/achamayou/validation"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["bin/*", "lib/**/*.rb", "schema/*.yml", "examples/*.yml", "LICENSE", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["cddl-map"]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "abnftt", "~> 0.2.11"
  spec.add_dependency "base32", "~> 0.3.4"
  spec.add_dependency "base45_lite", "~> 1.0.1"
  spec.add_dependency "cbor-diag", "= 0.11.8"
  spec.add_dependency "cddlc", "= 0.4.5"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "nokogiri", "~> 1.19"
  spec.add_dependency "regexp-examples", "~> 1.6"
  spec.add_dependency "scanf", "~> 1.0"
end
