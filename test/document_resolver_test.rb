# frozen_string_literal: true

require_relative "test_helper"

class DocumentResolverTest < Minitest::Test
  def test_fetches_url_without_a_content_pin
    with_workspace do |workspace|
      content = "<rfc><middle/></rfc>"
      manifest = manifest_with_document(
        workspace,
        "url" => "https://example.test/draft.xml"
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
      assert_equal content, resolved.content
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
