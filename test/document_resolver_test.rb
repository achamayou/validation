# frozen_string_literal: true

require_relative "test_helper"

class DocumentResolverTest < Minitest::Test
  def test_rejects_manifest_sha256_mismatch
    with_workspace do |workspace|
      workspace.join("doc.xml").binwrite("<rfc/>")
      manifest = manifest_with_document(
        workspace,
        "path" => "doc.xml",
        "sha256" => "0" * 64
      )

      error = assert_raises(CddlMap::Error) do
        CddlMap::DocumentResolver.new(manifest).resolve_all
      end

      assert_equal "document_hash", error.code
      assert_equal "doc", error.details.fetch(:document)
    end
  end

  def test_rejects_unpinned_url_before_fetching
    with_workspace do |workspace|
      manifest = manifest_with_document(
        workspace,
        "url" => "https://example.test/draft.xml"
      )

      error = assert_raises(CddlMap::Error) do
        CddlMap::DocumentResolver.new(manifest).resolve_all
      end

      assert_equal "document_unpinned", error.code
    end
  end

  def test_fetches_url_and_verifies_its_pin
    with_workspace do |workspace|
      content = "<rfc><middle/></rfc>"
      manifest = manifest_with_document(
        workspace,
        "url" => "https://example.test/draft.xml",
        "sha256" => Digest::SHA256.hexdigest(content)
      )
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, content)
      http = Object.new
      http.define_singleton_method(:request) { |_request| response }
      start = lambda do |*_arguments, **_keywords, &block|
        block.call(http)
      end

      resolved = Net::HTTP.stub(:start, start) do
        CddlMap::DocumentResolver.new(manifest).resolve_all.fetch("doc")
      end

      assert_equal content, resolved.content
      assert_equal Digest::SHA256.hexdigest(content), resolved.sha256
      assert_equal "url:https://example.test/draft.xml", resolved.source
    end
  end

  private

  def manifest_with_document(workspace, document)
    manifest_path = workspace.join("map.yml")
    write_manifest(
      manifest_path,
      documents: { "doc" => document },
      cddl: {
        "schema" => {
          "document" => "doc",
          "selector" => selector(block: { "ordinal" => 1 })
        }
      },
      edn: {
        "example" => {
          "document" => "doc",
          "selector" => selector(block: { "ordinal" => 2 }),
          "cddl" => "schema",
          "entry_rule" => "Entry",
          "expect" => "accept"
        }
      }
    )
    CddlMap::Manifest.load(manifest_path.to_s)
  end
end
