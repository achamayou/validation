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
end
