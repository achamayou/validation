# frozen_string_literal: true

require "nokogiri"

module CddlMap
  class Extractor
    BLOCK_ATTRIBUTES = %w[anchor name pn type].freeze

    Match = Struct.new(
      :text, :kind, :attributes, :section_attributes, :position,
      keyword_init: true
    ) do
      def lock_entry
        {
          "kind" => kind,
          "section" => section_attributes,
          "block" => attributes,
          "position" => position
        }
      end
    end

    def initialize(document)
      @document = document
      @xml = Nokogiri::XML::Document.parse(
        document.content,
        document.source,
        nil,
        Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET
      )
    rescue Nokogiri::XML::SyntaxError => e
      raise Error.new(
        "document #{document.id} is not well-formed RFCXML: #{e.message}",
        code: "document_xml",
        document: document.id,
        source: document.source
      )
    end

    def select(selector, selection:)
      section = select_section(selector.fetch("section"), selection)
      candidates = section.xpath(
        ".//*[local-name()='sourcecode' or local-name()='artwork']"
      )
      block_selector = selector.fetch("block")
      filters = block_selector.slice(*BLOCK_ATTRIBUTES)
      matched = candidates.each_with_index.filter_map do |node, index|
        next unless filters.all? { |name, value| node[name] == value }

        Match.new(
          text: node.text,
          kind: node.name.split(":").last,
          attributes: attributes(node),
          section_attributes: attributes(section, %w[anchor pn]),
          position: index + 1
        )
      end

      choose(matched, block_selector, selector, selection)
    end

    private

    def select_section(selector, selection)
      key, value = selector.first
      sections = @xml.xpath("//*[local-name()='section']").select { |node| node[key] == value }
      return sections.first if sections.length == 1

      raise Error.new(
        sections.empty? ? "section selector matched no section" : "section selector matched multiple sections",
        code: sections.empty? ? "section_not_found" : "section_not_unique",
        document: @document.id,
        selection: selection,
        selector: { "section" => selector },
        matches: sections.length
      )
    end

    def choose(matches, block_selector, selector, selection)
      if block_selector.key?("ordinal")
        match = matches[block_selector["ordinal"] - 1]
        return [match] if match

        raise_selection_error(
          "block ordinal #{block_selector['ordinal']} is outside #{matches.length} matches",
          "block_not_found",
          selector,
          selection,
          matches.length
        )
      end
      if block_selector["all"]
        return matches unless matches.empty?

        raise_selection_error(
          "block selector matched no blocks",
          "block_not_found",
          selector,
          selection,
          0
        )
      end
      return matches if matches.length == 1

      raise_selection_error(
        matches.empty? ? "block selector matched no blocks" : "block selector must match one block; use ordinal or all: true",
        matches.empty? ? "block_not_found" : "block_not_unique",
        selector,
        selection,
        matches.length
      )
    end

    def raise_selection_error(message, code, selector, selection, count)
      raise Error.new(
        message,
        code: code,
        document: @document.id,
        selection: selection,
        selector: selector,
        matches: count
      )
    end

    def attributes(node, names = BLOCK_ATTRIBUTES)
      names.each_with_object({}) do |name, result|
        result[name] = node[name] if node.key?(name)
      end
    end
  end
end
