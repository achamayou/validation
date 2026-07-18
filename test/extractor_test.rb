# frozen_string_literal: true

require_relative "test_helper"

class ExtractorTest < Minitest::Test
  def test_requires_unique_selection_without_ordinal_or_all
    extractor = extractor_for(
      [
        { anchor: "first", type: "cddl", text: "first = uint\n" },
        { anchor: "second", type: "cddl", text: "second = uint\n" }
      ]
    )

    error = assert_raises(CddlMap::Error) do
      extractor.select(
        selector(block: { "type" => "cddl" }),
        selection: "cddl.schema"
      )
    end

    assert_equal "block_not_unique", error.code
    assert_equal 2, error.details.fetch(:matches)
  end

  def test_supports_ordinal_all_generated_section_pn_and_legacy_artwork
    with_workspace do |workspace|
      xml = workspace.join("doc.xml")
      write_rfcxml(
        xml,
        sections: [
          {
            attributes: { anchor: "main", pn: "section-1" },
            blocks: [
              { anchor: "first", type: "cddl", text: "first = uint\n" },
              { anchor: "second", type: "cddl", text: "second = uint\n" },
              { kind: "artwork", anchor: "legacy", type: "cbor-diag", text: "  42\n" }
            ]
          }
        ]
      )
      document = CddlMap::DocumentResolver::ResolvedDocument.new(
        id: "doc",
        source: "path:doc.xml",
        content: xml.binread,
        sha256: "unused"
      )
      extractor = CddlMap::Extractor.new(document)

      second = extractor.select(
        selector(
          section: { "pn" => "section-1" },
          block: { "type" => "cddl", "ordinal" => 2 }
        ),
        selection: "cddl.second"
      )
      all = extractor.select(
        selector(block: { "type" => "cddl", "all" => true }),
        selection: "cddl.all"
      )
      artwork = extractor.select(
        selector(block: { "anchor" => "legacy" }),
        selection: "edn.legacy"
      )

      assert_equal "second = uint\n", second.fetch(0).text
      assert_equal 2, all.length
      assert_equal "artwork", artwork.fetch(0).kind
      assert_equal "  42\n", artwork.fetch(0).text
    end
  end

  private

  def extractor_for(blocks)
    xml = "<?xml version=\"1.0\"?><rfc><middle><section anchor=\"main\">" \
          "#{blocks.map { |block| block_xml(block) }.join}</section></middle></rfc>"
    document = CddlMap::DocumentResolver::ResolvedDocument.new(
      id: "doc",
      source: "memory",
      content: xml,
      sha256: "unused"
    )
    CddlMap::Extractor.new(document)
  end

  def block_xml(block)
    "<sourcecode anchor=\"#{block.fetch(:anchor)}\" type=\"#{block.fetch(:type)}\">" \
      "<![CDATA[#{block.fetch(:text)}]]></sourcecode>"
  end
end
