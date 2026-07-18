# frozen_string_literal: true

require_relative "test_helper"

class ManifestTest < Minitest::Test
  def test_rejects_unknown_keys
    with_workspace do |workspace|
      manifest = workspace.join("map.yml")
      manifest.binwrite(
        YAML.dump(
          "version" => 1,
          "documents" => {
            "doc" => { "path" => "doc.xml", "unexpected" => true }
          },
          "cddl" => {},
          "edn" => {}
        )
      )

      error = assert_raises(CddlMap::Error) { CddlMap::Manifest.load(manifest.to_s) }

      assert_equal "manifest_unknown_key", error.code
      assert_includes error.message, "unexpected"
    end
  end

  def test_normalizes_rfc_and_single_cddl_root
    with_workspace do |workspace|
      manifest = workspace.join("map.yml")
      write_manifest(
        manifest,
        documents: { "rfc" => { "rfc" => "RFC 9052" } },
        cddl: {
          "schema" => {
            "document" => "rfc",
            "selector" => selector(block: { "ordinal" => 1 })
          }
        },
        edn: {
          "example" => {
            "document" => "rfc",
            "selector" => selector(block: { "ordinal" => 2 }),
            "cddl" => "schema",
            "entry_rule" => "Entry",
            "expect" => "accept"
          }
        }
      )

      parsed = CddlMap::Manifest.load(manifest.to_s)

      assert_equal 9052, parsed.documents.fetch("rfc").source_value
      assert_equal ["schema"], parsed.edn.fetch("example").cddl
    end
  end
end
