# frozen_string_literal: true

require_relative "test_helper"

class ManifestTest < Minitest::Test
  def test_schema_rejects_invalid_manifests
    mutations = [
      ->(raw) { raw["documents"]["doc"]["unexpected"] = true },
      ->(raw) { raw["cddl"]["schema"]["selector"]["block"] = {"ordinal" => 1, "all" => true} },
      ->(raw) { raw["documents"] = {9052 => {"rfc" => 9052}} }
    ]

    mutations.each do |mutate|
      with_manifest do |path, raw|
        mutate.call(raw)
        path.binwrite(YAML.dump(raw))

        error = assert_raises(CddlMap::Error) { CddlMap::Manifest.load(path.to_s) }
        assert_equal "manifest_schema", error.code
      end
    end
  end

  def test_manifest_schema_is_valid
    schema = YAML.safe_load(File.binread(CddlMap::Manifest::SCHEMA_PATH), aliases: false)

    assert JSONSchemer.valid_schema?(schema)
  end

  def test_normalizes_rfc_and_single_cddl_root
    with_manifest do |path, raw|
      raw["documents"]["doc"] = {"rfc" => "RFC 9052"}
      path.binwrite(YAML.dump(raw))

      parsed = CddlMap::Manifest.load(path.to_s)

      assert_equal 9052, parsed.documents.fetch("doc").source_value
      assert_equal ["schema"], parsed.edn.fetch("example").cddl
    end
  end

  private

  def with_manifest
    with_workspace do |workspace|
      raw = {
        "version" => 1,
        "documents" => {"doc" => {"path" => "doc.xml"}},
        "cddl" => {
          "schema" => {
            "document" => "doc",
            "selector" => selector(block: {"ordinal" => 1})
          }
        },
        "edn" => {
          "example" => {
            "document" => "doc",
            "selector" => selector(block: {"ordinal" => 2}),
            "cddl" => "schema",
            "entry_rule" => "Entry",
            "expect" => "accept"
          }
        }
      }
      yield workspace.join("map.yml"), raw
    end
  end
end
