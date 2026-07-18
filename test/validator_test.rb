# frozen_string_literal: true

require_relative "test_helper"

class ValidatorTest < Minitest::Test
  def test_same_document_dependency_is_staged_dependency_first
    with_workspace do |workspace|
      manifest, log = same_document_project(workspace)

      report = run_fake(manifest, log_path: log, update_lock: true)

      schema = "schema-#{CddlMap::Stager.module_stem('message')}.cddl"
      record = read_log(log).find { |item| item["argv"].last == schema }
      expected = [
        ";# include #{CddlMap::Stager.module_stem('base')}\n",
        ";# include #{CddlMap::Stager.module_stem('message')}\n"
      ].join
      assert_equal expected, record.fetch("files").fetch(schema)
      assert_equal "updated", report.fetch("lock").fetch("status")
    end
  end

  def test_cross_document_dependency_is_staged
    with_workspace do |workspace|
      first = workspace.join("first.xml")
      second = workspace.join("second.xml")
      write_rfcxml(
        first,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [{ anchor: "base", type: "cddl", text: "Base = uint\n" }]
          }
        ]
      )
      write_rfcxml(
        second,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "message", type: "cddl", text: "Message = Base\n" },
              { anchor: "example", type: "cbor-diag", text: "1\n" }
            ]
          }
        ]
      )
      manifest = workspace.join("map.yml")
      log = workspace.join("fake.log")
      write_manifest(
        manifest,
        documents: {
          "first" => { "path" => "first.xml" },
          "second" => { "path" => "second.xml" }
        },
        cddl: {
          "base" => cddl_spec(document: "first", anchor: "base"),
          "message" => cddl_spec(document: "second", anchor: "message", depends_on: ["base"])
        },
        edn: {
          "example" => edn_spec(document: "second", anchor: "example", cddl: "message")
        }
      )

      report = run_fake(manifest, log_path: log, update_lock: true)

      schema = "schema-#{CddlMap::Stager.module_stem('message')}.cddl"
      body = read_log(log).find { |item| item["argv"].last == schema }.fetch("files").fetch(schema)
      assert_includes body, CddlMap::Stager.module_stem("base")
      assert_includes body, CddlMap::Stager.module_stem("message")
      assert_equal 2, report.fetch("documents").length
    end
  end

  def test_dependency_cycle_is_materialized_once_and_left_to_cddlc
    with_workspace do |workspace|
      xml = workspace.join("doc.xml")
      write_rfcxml(
        xml,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "a", type: "cddl", text: "A = [B]\n" },
              { anchor: "b", type: "cddl", text: "B = A / uint\n" },
              { anchor: "example", type: "cbor-diag", text: "1\n" }
            ]
          }
        ]
      )
      manifest = workspace.join("map.yml")
      log = workspace.join("fake.log")
      write_manifest(
        manifest,
        documents: { "doc" => { "path" => "doc.xml" } },
        cddl: {
          "a" => cddl_spec(document: "doc", anchor: "a", depends_on: ["b"]),
          "b" => cddl_spec(document: "doc", anchor: "b", depends_on: ["a"])
        },
        edn: {
          "example" => edn_spec(document: "doc", anchor: "example", cddl: "a")
        }
      )

      run_fake(manifest, log_path: log, update_lock: true)

      schema = "schema-#{CddlMap::Stager.module_stem('a')}.cddl"
      body = read_log(log).find { |item| item["argv"].last == schema }.fetch("files").fetch(schema)
      assert_equal 1, body.scan(CddlMap::Stager.module_stem("a")).length
      assert_equal 1, body.scan(CddlMap::Stager.module_stem("b")).length
    end
  end

  def test_malformed_edn_is_not_counted_as_expected_rejection
    with_workspace do |workspace|
      manifest, log = one_block_project(workspace, edn_text: "MALFORMED", expect: "reject")

      error = assert_raises(CddlMap::Error) do
        run_fake(manifest, log_path: log, update_lock: true)
      end

      assert_equal "cddlc_example", error.code
      assert_includes error.details.fetch(:stderr), "Expected an EDN item"
    end
  end

  def test_expected_rejection_succeeds
    with_workspace do |workspace|
      manifest, log = one_block_project(workspace, edn_text: "REJECT\n", expect: "reject")

      report = run_fake(manifest, log_path: log, update_lock: true)

      assert_equal "rejected", report.fetch("examples").fetch(0).fetch("outcome")
    end
  end

  def test_document_hash_and_selector_drift_fail_against_lock
    with_workspace do |workspace|
      xml = workspace.join("doc.xml")
      write_rfcxml(
        xml,
        sections: [
          {
            attributes: { anchor: "main" },
            blocks: [
              { anchor: "one", type: "cddl", text: "Message = uint\n" },
              { anchor: "two", type: "cddl", text: "Message = uint\n" },
              { anchor: "example", type: "cbor-diag", text: "1\n" }
            ]
          }
        ]
      )
      manifest = workspace.join("map.yml")
      log = workspace.join("fake.log")
      write_drift_manifest(manifest, "one")
      run_fake(manifest, log_path: log, update_lock: true)

      write_drift_manifest(manifest, "two")
      selector_error = assert_raises(CddlMap::Error) do
        run_fake(manifest, log_path: log)
      end
      assert_equal "lock_drift", selector_error.code
      assert selector_error.details.fetch(:differences).any? { |item| item.include?("selector") }

      write_drift_manifest(manifest, "one")
      xml.binwrite(xml.binread.sub("Message = uint", "Message = int"))
      hash_error = assert_raises(CddlMap::Error) do
        run_fake(manifest, log_path: log)
      end
      assert_equal "lock_drift", hash_error.code
      assert hash_error.details.fetch(:differences).any? { |item| item.include?("documents.doc.sha256") }
    end
  end

  def test_cddlc_invocations_use_relative_paths_safe_include_path_and_exact_text
    with_workspace do |workspace|
      cddl_text = "Message = uint\n\n"
      edn_text = "  1\n"
      manifest, log = one_block_project(
        workspace,
        cddl_text: cddl_text,
        edn_text: edn_text,
        expect: "accept"
      )

      run_fake(manifest, log_path: log, update_lock: true)

      records = read_log(log)
      assert_equal 2, records.length
      schema_record = records.find { |record| record.fetch("argv").include?("-u") }
      example_record = records.find { |record| record.fetch("argv").include?("-d") }
      schema_name = "schema-#{CddlMap::Stager.module_stem('schema')}.cddl"
      example_name = example_record.fetch("argv")[example_record.fetch("argv").index("-d") + 1]
      assert_equal ["-u", "-2", "-t", "cddl", schema_name], schema_record.fetch("argv")
      assert_equal ["-2", "-s", "Message", "-d", example_name, schema_name], example_record.fetch("argv")
      assert records.all? { |record| record.fetch("include_path") == ".:" }
      assert_equal 1, records.map { |record| record.fetch("cwd") }.uniq.length
      assert records.all? { |record| record.fetch("argv").all? { |argument| !argument.include?("/") } }
      module_name = "#{CddlMap::Stager.module_stem('schema')}.cddl"
      assert_equal cddl_text, schema_record.fetch("files").fetch(module_name)
      assert_equal edn_text, example_record.fetch("files").fetch(example_name)
    end
  end

  def test_undefined_name_output_fails_even_when_cddlc_exits_zero
    with_workspace do |workspace|
      manifest, log = one_block_project(
        workspace,
        cddl_text: "UNDEFINED_TRIGGER\n",
        edn_text: "1\n",
        expect: "accept"
      )

      error = assert_raises(CddlMap::Error) do
        run_fake(manifest, log_path: log, update_lock: true)
      end

      assert_equal "cddlc_schema", error.code
      assert_equal [";;; *** undefined: missing-rule"], error.details.fetch(:undefined)
      assert_equal 0, error.details.fetch(:exit_status)
    end
  end

  def test_schema_stderr_fails_even_when_cddlc_exits_zero
    with_workspace do |workspace|
      manifest, log = one_block_project(
        workspace,
        cddl_text: "SCHEMA_WARNING\n",
        edn_text: "1\n",
        expect: "accept"
      )

      error = assert_raises(CddlMap::Error) do
        run_fake(manifest, log_path: log, update_lock: true)
      end

      assert_equal "cddlc_schema", error.code
      assert_includes error.details.fetch(:stderr), "synthetic schema warning"
      assert_equal 0, error.details.fetch(:exit_status)
    end
  end

  private

  def same_document_project(workspace)
    xml = workspace.join("doc.xml")
    write_rfcxml(
      xml,
      sections: [
        {
          attributes: { anchor: "main" },
          blocks: [
            { anchor: "base", type: "cddl", text: "Base = uint\n" },
            { anchor: "message", type: "cddl", text: "Message = Base\n" },
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
        "base" => cddl_spec(document: "doc", anchor: "base"),
        "message" => cddl_spec(document: "doc", anchor: "message", depends_on: ["base"])
      },
      edn: {
        "example" => edn_spec(document: "doc", anchor: "example", cddl: "message")
      }
    )
    [manifest, workspace.join("fake.log")]
  end

  def one_block_project(
    workspace,
    cddl_text: "Message = uint\n",
    edn_text: "1\n",
    expect:
  )
    xml = workspace.join("doc.xml")
    write_rfcxml(
      xml,
      sections: [
        {
          attributes: { anchor: "main" },
          blocks: [
            { anchor: "schema", type: "cddl", text: cddl_text },
            { anchor: "example", type: "cbor-diag", text: edn_text }
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
        "example" => edn_spec(
          document: "doc",
          anchor: "example",
          cddl: "schema",
          expect: expect
        )
      }
    )
    [manifest, workspace.join("fake.log")]
  end

  def write_drift_manifest(path, cddl_anchor)
    write_manifest(
      path,
      documents: { "doc" => { "path" => "doc.xml" } },
      cddl: {
        "schema" => cddl_spec(document: "doc", anchor: cddl_anchor)
      },
      edn: {
        "example" => edn_spec(document: "doc", anchor: "example", cddl: "schema")
      }
    )
  end
end
