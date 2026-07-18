# frozen_string_literal: true

require "yaml"

module CddlMap
  class Manifest
    ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
    SHA256_PATTERN = /\A[0-9a-fA-F]{64}\z/
    ROOT_KEYS = %w[version documents cddl edn].freeze
    DOCUMENT_KEYS = %w[path rfc url sha256].freeze
    CDDL_KEYS = %w[document selector depends_on].freeze
    EDN_KEYS = %w[document selector cddl entry_rule expect].freeze
    SELECTOR_KEYS = %w[section block].freeze
    SECTION_KEYS = %w[anchor pn].freeze
    BLOCK_KEYS = %w[anchor name pn type ordinal all].freeze

    DocumentSpec = Struct.new(
      :id, :source_kind, :source_value, :sha256,
      keyword_init: true
    ) do
      def source_identity
        "#{source_kind}:#{source_value}"
      end
    end

    CddlSpec = Struct.new(
      :name, :document, :selector, :depends_on,
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
      @documents = {}
      @cddl = {}
      @edn = {}
    end

    def load!
      raw = YAML.safe_load(
        File.binread(path),
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false
      )
      hash!(raw, "manifest")
      keys!(raw, ROOT_KEYS, "manifest", required: ROOT_KEYS)
      value!(raw["version"] == 1, "manifest version must be 1", "manifest.version")

      parse_documents(hash!(raw["documents"], "manifest.documents"))
      parse_cddl(hash!(raw["cddl"], "manifest.cddl"))
      parse_edn(hash!(raw["edn"], "manifest.edn"))
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

    def parse_documents(raw)
      value!(!raw.empty?, "at least one document is required", "manifest.documents")
      raw.each do |id, value|
        id!(id, "manifest.documents")
        spec = hash!(value, "manifest.documents.#{id}")
        keys!(spec, DOCUMENT_KEYS, "manifest.documents.#{id}")

        source_keys = %w[path rfc url].select { |key| spec.key?(key) }
        value!(
          source_keys.length == 1,
          "exactly one of path, rfc, or url is required",
          "manifest.documents.#{id}"
        )
        kind = source_keys.first
        source = normalize_source(kind, spec[kind], "manifest.documents.#{id}.#{kind}")
        sha256 = spec["sha256"]
        if sha256
          string!(sha256, "manifest.documents.#{id}.sha256")
          value!(
            SHA256_PATTERN.match?(sha256),
            "sha256 must contain 64 hexadecimal characters",
            "manifest.documents.#{id}.sha256"
          )
          sha256 = sha256.downcase
        end

        documents[id] = DocumentSpec.new(
          id: id,
          source_kind: kind,
          source_value: source,
          sha256: sha256
        )
      end
    end

    def parse_cddl(raw)
      value!(!raw.empty?, "at least one CDDL block is required", "manifest.cddl")
      raw.each do |name, value|
        id!(name, "manifest.cddl")
        spec = hash!(value, "manifest.cddl.#{name}")
        keys!(
          spec,
          CDDL_KEYS,
          "manifest.cddl.#{name}",
          required: %w[document selector]
        )
        document = string!(spec["document"], "manifest.cddl.#{name}.document")
        selector = parse_selector(spec["selector"], "manifest.cddl.#{name}.selector")
        depends_on = spec.fetch("depends_on", [])
        array!(depends_on, "manifest.cddl.#{name}.depends_on")
        depends_on.each_with_index do |dependency, index|
          id!(dependency, "manifest.cddl.#{name}.depends_on[#{index}]")
        end
        value!(
          depends_on.uniq.length == depends_on.length,
          "dependencies must not be repeated",
          "manifest.cddl.#{name}.depends_on"
        )

        cddl[name] = CddlSpec.new(
          name: name,
          document: document,
          selector: selector,
          depends_on: depends_on.dup.freeze
        )
      end
    end

    def parse_edn(raw)
      value!(!raw.empty?, "at least one EDN set is required", "manifest.edn")
      raw.each do |name, value|
        id!(name, "manifest.edn")
        spec = hash!(value, "manifest.edn.#{name}")
        keys!(spec, EDN_KEYS, "manifest.edn.#{name}", required: EDN_KEYS)
        document = string!(spec["document"], "manifest.edn.#{name}.document")
        selector = parse_selector(spec["selector"], "manifest.edn.#{name}.selector")
        roots = spec["cddl"]
        roots = [roots] if roots.is_a?(String)
        array!(roots, "manifest.edn.#{name}.cddl")
        value!(!roots.empty?, "at least one CDDL block is required", "manifest.edn.#{name}.cddl")
        roots.each_with_index { |root, index| id!(root, "manifest.edn.#{name}.cddl[#{index}]") }
        value!(
          roots.uniq.length == roots.length,
          "CDDL blocks must not be repeated",
          "manifest.edn.#{name}.cddl"
        )
        entry_rule = string!(spec["entry_rule"], "manifest.edn.#{name}.entry_rule")
        value!(!entry_rule.empty?, "entry_rule must not be empty", "manifest.edn.#{name}.entry_rule")
        expect = string!(spec["expect"], "manifest.edn.#{name}.expect")
        value!(
          %w[accept reject].include?(expect),
          "expect must be accept or reject",
          "manifest.edn.#{name}.expect"
        )

        edn[name] = EdnSpec.new(
          name: name,
          document: document,
          selector: selector,
          cddl: roots.dup.freeze,
          entry_rule: entry_rule,
          expect: expect
        )
      end
    end

    def parse_selector(value, location)
      selector = hash!(value, location)
      keys!(selector, SELECTOR_KEYS, location, required: SELECTOR_KEYS)
      section = hash!(selector["section"], "#{location}.section")
      keys!(section, SECTION_KEYS, "#{location}.section")
      present_section_keys = SECTION_KEYS.select { |key| section.key?(key) }
      value!(
        present_section_keys.length == 1,
        "section must contain exactly one of anchor or pn",
        "#{location}.section"
      )
      section.each { |key, item| nonempty_string!(item, "#{location}.section.#{key}") }

      block = hash!(selector["block"], "#{location}.block")
      keys!(block, BLOCK_KEYS, "#{location}.block")
      %w[anchor name pn type].each do |key|
        nonempty_string!(block[key], "#{location}.block.#{key}") if block.key?(key)
      end
      if block.key?("ordinal")
        value!(
          block["ordinal"].is_a?(Integer) && block["ordinal"].positive?,
          "ordinal must be a positive integer",
          "#{location}.block.ordinal"
        )
      end
      if block.key?("all")
        value!(
          block["all"] == true,
          "all may only be set to true",
          "#{location}.block.all"
        )
      end
      value!(
        !(block.key?("ordinal") && block.key?("all")),
        "ordinal and all are mutually exclusive",
        "#{location}.block"
      )

      {
        "section" => section.dup.freeze,
        "block" => block.dup.freeze
      }.freeze
    end

    def validate_references!
      cddl.each_value do |spec|
        reference!(documents, spec.document, "manifest.cddl.#{spec.name}.document", "document")
        spec.depends_on.each do |dependency|
          reference!(
            cddl,
            dependency,
            "manifest.cddl.#{spec.name}.depends_on",
            "CDDL block"
          )
        end
      end
      edn.each_value do |spec|
        reference!(documents, spec.document, "manifest.edn.#{spec.name}.document", "document")
        spec.cddl.each do |root|
          reference!(cddl, root, "manifest.edn.#{spec.name}.cddl", "CDDL block")
        end
      end
    end

    def normalize_source(kind, value, location)
      case kind
      when "path", "url"
        nonempty_string!(value, location)
      when "rfc"
        number =
          case value
          when Integer
            value
          when String
            match = /\A(?:RFC\s*)?([0-9]+)\z/i.match(value)
            match && match[1].to_i
          end
        value!(number&.positive?, "rfc must be a positive RFC number", location)
        number
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

    def keys!(value, allowed, location, required: [])
      unknown = value.keys - allowed
      unless unknown.empty?
        raise Error.new(
          "#{location} contains unknown keys: #{unknown.join(', ')}",
          code: "manifest_unknown_key",
          location: location,
          keys: unknown
        )
      end
      missing = required - value.keys
      return if missing.empty?

      raise Error.new(
        "#{location} is missing keys: #{missing.join(', ')}",
        code: "manifest_missing_key",
        location: location,
        keys: missing
      )
    end

    def hash!(value, location)
      return value if value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }

      raise Error.new(
        "#{location} must be a mapping with string keys",
        code: "manifest_type",
        location: location
      )
    end

    def array!(value, location)
      return value if value.is_a?(Array)

      raise Error.new(
        "#{location} must be a sequence",
        code: "manifest_type",
        location: location
      )
    end

    def string!(value, location)
      return value if value.is_a?(String)

      raise Error.new(
        "#{location} must be a string",
        code: "manifest_type",
        location: location
      )
    end

    def nonempty_string!(value, location)
      string!(value, location)
      value!(!value.empty?, "#{location} must not be empty", location)
      value
    end

    def id!(value, location)
      nonempty_string!(value, location)
      value!(
        ID_PATTERN.match?(value),
        "#{location} identifier #{value.inspect} is invalid",
        location
      )
      value
    end

    def value!(condition, message, location)
      return if condition

      raise Error.new(
        message,
        code: "manifest_value",
        location: location
      )
    end
  end
end
