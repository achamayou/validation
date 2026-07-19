# frozen_string_literal: true

require_relative "test_helper"

class CliTest < Minitest::Test
  def test_validate_emits_machine_readable_result
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
      stdout = StringIO.new
      stderr = StringIO.new
      log = workspace.join("fake.log")

      status = with_environment("FAKE_CDDLC_LOG" => log.to_s) do
        CddlMap::CLI.start(
          [
            "validate",
            "--json",
            "--update-lock",
            "--cddlc",
            fake_executable(workspace).to_s,
            manifest.to_s
          ],
          stdout: stdout,
          stderr: stderr
        )
      end

      payload = JSON.parse(stdout.string)
      assert_equal 0, status
      assert_equal true, payload.fetch("ok")
      assert_equal "updated", payload.dig("result", "lock", "status")
      assert_empty stderr.string
    end
  end

  def test_human_result_counts_skipped_examples_separately
    report = {
      "documents" => [],
      "cddl_blocks" => 1,
      "examples" => [
        { "outcome" => "accepted" },
        { "outcome" => "rejected" },
        { "outcome" => "skipped" }
      ],
      "lock" => { "status" => "verified", "path" => "example.lock.yml" }
    }

    output = CddlMap::Formatter.success(report)

    assert_includes output, "examples: 1 accepted, 1 rejected as expected, 1 skipped"
  end
end
