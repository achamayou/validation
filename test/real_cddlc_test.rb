# frozen_string_literal: true

require_relative "test_helper"

class RealCddlcTest < Minitest::Test
  def test_real_cddlc_smoke_when_installed
    skip "cddlc 0.4.5 is not installed" unless CddlMap::CddlcRunner.available?

    with_workspace do |workspace|
      xml = workspace.join("doc.xml")
      write_rfcxml(
        xml,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "schema", type: "cddl", text: "Message = uint\n" },
              { anchor: "example", type: "cbor-diag", text: "1\n" }
            ]
          }
        ]
      )
      manifest = workspace.join("map.yml")
      write_manifest(
        manifest,
        documents: { "doc" => { "path" => "doc.xml" } },
        cddl: {
          "schema" => cddl_spec(document: "doc", anchor: "schema")
        },
        edn: {
          "example" => edn_spec(document: "doc", anchor: "example", cddl: "schema")
        }
      )

      report = CddlMap::Validator.new(manifest.to_s, update_lock: true).call

      assert_equal "accepted", report.fetch("examples").fetch(0).fetch("outcome")
    end
  end

  def test_real_cddlc_resolves_lazy_import_without_overwriting_local_rules
    skip "cddlc 0.4.5 is not installed" unless CddlMap::CddlcRunner.available?

    with_workspace do |workspace|
      base = workspace.join("base.xml")
      root = workspace.join("root.xml")
      write_rfcxml(
        base,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "base", type: "cddl", text: "Shared = uint\nBase = Shared\n" }
            ]
          }
        ]
      )
      write_rfcxml(
        root,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "message", type: "cddl", text: "Shared = tstr\nMessage = Base\n" },
              { anchor: "example", type: "cbor-diag", text: "\"imported\"\n" }
            ]
          }
        ]
      )
      manifest = workspace.join("map.yml")
      write_manifest(
        manifest,
        documents: {
          "base" => { "path" => "base.xml" },
          "root" => { "path" => "root.xml" }
        },
        cddl: {
          "base" => cddl_spec(document: "base", anchor: "base"),
          "message" => cddl_spec(document: "root", anchor: "message", imports: ["base"])
        },
        edn: {
          "example" => edn_spec(document: "root", anchor: "example", cddl: "message")
        }
      )

      report = CddlMap::Validator.new(manifest.to_s, update_lock: true).call

      assert_equal "accepted", report.fetch("examples").fetch(0).fetch("outcome")
    end
  end

  def test_real_cddlc_import_preserves_eager_choice_augmentation
    skip "cddlc 0.4.5 is not installed" unless CddlMap::CddlcRunner.available?

    with_workspace do |workspace|
      base = workspace.join("base.xml")
      root = workspace.join("root.xml")
      write_rfcxml(
        base,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "base", type: "cddl", text: "Base = uint\n" },
              { anchor: "extension", type: "cddl", text: "Base /= tstr\n" }
            ]
          }
        ]
      )
      write_rfcxml(
        root,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "message", type: "cddl", text: "Message = Base\n" },
              { anchor: "integer", type: "cbor-diag", text: "1\n" }
            ]
          }
        ]
      )
      manifest = workspace.join("map.yml")
      write_manifest(
        manifest,
        documents: {
          "base" => { "path" => "base.xml" },
          "root" => { "path" => "root.xml" }
        },
        cddl: {
          "base" => cddl_spec(document: "base", anchor: "base"),
          "extension" => cddl_spec(
            document: "base",
            anchor: "extension",
            depends_on: ["base"]
          ),
          "message" => cddl_spec(document: "root", anchor: "message", imports: ["extension"])
        },
        edn: {
          "example" => edn_spec(document: "root", anchor: "integer", cddl: "message")
        }
      )

      report = CddlMap::Validator.new(manifest.to_s, update_lock: true).call

      assert_equal "accepted", report.fetch("examples").fetch(0).fetch("outcome")
    end
  end
end
