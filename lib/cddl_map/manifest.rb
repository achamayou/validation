# frozen_string_literal: true

require "json_schemer"
require "yaml"

module CddlMap
  class Manifest
    SCHEMA_PATH = File.expand_path("../../schema/manifest-v1.schema.yml", __dir__)
    CDDL_IDENTIFIER = /\A[A-Za-z@_$](?:[-.]*[A-Za-z@_$0-9])*\z/
    SCHEMER = JSONSchemer.schema(
      YAML.safe_load(File.binread(SCHEMA_PATH), aliases: false)
    )

    DocumentSpec = Struct.new(
      :id, :source_kind, :source_value, :sha256,
      keyword_init: true
    ) do
      def source_identity
        "#{source_kind}:#{source_value}"
      end
    end

    CddlSpec = Struct.new(
      :name, :document, :selector, :depends_on, :imports,
      keyword_init: true
    )

    ImportSpec = Struct.new(
      :cddl, :rules,
      keyword_init: true
    )

    EdnSpec = Struct.new(
      :name, :document, :selector, :cddl, :entry_rule, :expect,
      keyword_init: true
    )

    attr_reader :path, :documents, :cddl, :edn

    def self.load(path)
      new(path).tap(&:load!)
    end

    def initialize(path)
      @path = File.expand_path(path)
    end

    def load!
      raw = YAML.safe_load(
        File.binread(path),
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false
      )
      validate_schema!(raw)
      validate_identifier_keys!(raw)
      @documents = build_documents(raw.fetch("documents"))
      @cddl = build_cddl(raw.fetch("cddl"))
      @edn = build_edn(raw.fetch("edn"))
      validate_references!
      self
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      raise Error.new(
        "cannot read manifest #{path}: #{e.message}",
        code: "manifest_io",
        path: path
      )
    rescue Psych::Exception => e
      raise Error.new(
        "invalid YAML in #{path}: #{e.message}",
        code: "manifest_yaml",
        path: path
      )
    end

    private

    def validate_schema!(raw)
      errors = SCHEMER.validate(raw).to_a
      return if errors.empty?

      details = errors.first(20).map do |error|
        {
          "path" => error.fetch("data_pointer"),
          "type" => error.fetch("type"),
          "message" => error.fetch("error")
        }
      end
      raise Error.new(
        "manifest does not match version 1 schema: #{details.first.fetch('message')}",
        code: "manifest_schema",
        path: path,
        errors: details
      )
    end

    def validate_identifier_keys!(raw)
      invalid = %w[documents cddl edn].to_h do |section|
        [section, raw.fetch(section).keys.reject { |key| key.is_a?(String) }]
      end.reject { |_section, keys| keys.empty? }
      return if invalid.empty?

      raise Error.new(
        "manifest identifiers must be YAML strings: #{invalid.inspect}",
        code: "manifest_schema",
        path: path,
        errors: invalid
      )
    end

    def build_documents(raw)
      raw.to_h do |id, spec|
        kind = %w[path rfc url].find { |candidate| spec.key?(candidate) }
        source = spec.fetch(kind)
        source = normalize_rfc(source) if kind == "rfc"
        [
          id,
          DocumentSpec.new(
            id: id,
            source_kind: kind,
            source_value: source,
            sha256: spec["sha256"]&.downcase
          )
        ]
      end
    end

    def build_cddl(raw)
      raw.to_h do |name, spec|
        [
          name,
          CddlSpec.new(
            name: name,
            document: spec.fetch("document"),
            selector: selector(spec.fetch("selector")),
            depends_on: spec.fetch("depends_on", []).dup.freeze,
            imports: build_imports(spec.fetch("imports", []))
          )
        ]
      end
    end

    def build_imports(raw)
      raw.map do |item|
        if item.is_a?(String)
          ImportSpec.new(cddl: item, rules: nil)
        else
          ImportSpec.new(
            cddl: item.fetch("cddl"),
            rules: import_rules(item.fetch("rules"))
          )
        end
      end.freeze
    end

    def import_rules(rules)
      return rules.dup.freeze if rules.all? { |rule| CDDL_IDENTIFIER.match?(rule) }

      raise Error.new(
        "manifest CDDL import contains an invalid rule name",
        code: "manifest_schema",
        path: path,
        errors: rules.reject { |rule| CDDL_IDENTIFIER.match?(rule) }
      )
    end

    def build_edn(raw)
      raw.to_h do |name, spec|
        roots = spec.fetch("cddl")
        roots = [roots] if roots.is_a?(String)
        [
          name,
          EdnSpec.new(
            name: name,
            document: spec.fetch("document"),
            selector: selector(spec.fetch("selector")),
            cddl: roots.dup.freeze,
            entry_rule: spec.fetch("entry_rule"),
            expect: spec.fetch("expect")
          )
        ]
      end
    end

    def selector(raw)
      {
        "section" => raw.fetch("section").dup.freeze,
        "block" => raw.fetch("block").dup.freeze
      }.freeze
    end

    def normalize_rfc(value)
      return value if value.is_a?(Integer)

      value.sub(/\A(?:RFC\s*)?/i, "").to_i
    end

    def validate_references!
      cddl.each_value do |spec|
        reference!(documents, spec.document, "manifest.cddl.#{spec.name}.document", "document")
        spec.depends_on.each do |dependency|
          reference!(cddl, dependency, "manifest.cddl.#{spec.name}.depends_on", "CDDL block")
        end
        spec.imports.each do |dependency|
          reference!(cddl, dependency.cddl, "manifest.cddl.#{spec.name}.imports", "CDDL block")
        end
      end
      edn.each_value do |spec|
        reference!(documents, spec.document, "manifest.edn.#{spec.name}.document", "document")
        spec.cddl.each do |root|
          reference!(cddl, root, "manifest.edn.#{spec.name}.cddl", "CDDL block")
        end
      end
    end

    def reference!(collection, name, location, kind)
      return if collection.key?(name)

      raise Error.new(
        "#{location} references unknown #{kind} #{name.inspect}",
        code: "manifest_reference",
        location: location,
        reference: name
      )
    end
  end
end
