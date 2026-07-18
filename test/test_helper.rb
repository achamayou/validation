# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "cgi"
require "json"
require "minitest/autorun"
require "pathname"
require "rbconfig"
require "shellwords"
require "stringio"
require "tmpdir"
require "yaml"
require "cddl_map"

module CddlMapTestSupport
  FAKE_CDDLC = File.expand_path("fixtures/fake_cddlc.rb", __dir__)

  def with_workspace
    Dir.mktmpdir("cddl-map-test-") { |directory| yield Pathname(directory) }
  end

  def write_rfcxml(path, sections:)
    section_xml = sections.map do |section|
      attributes = xml_attributes(section.fetch(:attributes))
      blocks = section.fetch(:blocks).map do |block|
        kind = block.fetch(:kind, "sourcecode")
        attrs = xml_attributes(block.reject { |key, _| %i[kind text].include?(key) })
        text = block.fetch(:text)
        raise "test fixture cannot contain ]]>" if text.include?("]]>")

        "<#{kind}#{attrs}><![CDATA[#{text}]]></#{kind}>"
      end.join
      "<section#{attributes}>#{blocks}</section>"
    end.join
    path.binwrite("<?xml version=\"1.0\" encoding=\"UTF-8\"?><rfc><middle>#{section_xml}</middle></rfc>")
  end

  def write_manifest(path, documents:, cddl:, edn:)
    path.binwrite(
      YAML.dump(
        "version" => 1,
        "documents" => documents,
        "cddl" => cddl,
        "edn" => edn
      )
    )
  end

  def selector(section: { "anchor" => "main" }, block:)
    { "section" => section, "block" => block }
  end

  def cddl_spec(document:, anchor:, depends_on: [])
    {
      "document" => document,
      "selector" => selector(block: { "anchor" => anchor }),
      "depends_on" => depends_on
    }
  end

  def edn_spec(document:, anchor:, cddl:, expect: "accept", entry_rule: "Message")
    {
      "document" => document,
      "selector" => selector(block: { "anchor" => anchor }),
      "cddl" => cddl,
      "entry_rule" => entry_rule,
      "expect" => expect
    }
  end

  def run_fake(manifest_path, log_path:, **options)
    CddlMap::Validator.new(
      manifest_path.to_s,
      cddlc_command: [RbConfig.ruby, FAKE_CDDLC],
      cddlc_environment: { "FAKE_CDDLC_LOG" => log_path.to_s },
      **options
    ).call
  end

  def read_log(path)
    path.readlines(chomp: true).map { |line| JSON.parse(line) }
  end

  def fake_executable(workspace)
    executable = workspace.join("fake-cddlc")
    executable.binwrite(
      "#!/bin/sh\nexec #{Shellwords.escape(RbConfig.ruby)} " \
      "#{Shellwords.escape(FAKE_CDDLC)} \"$@\"\n"
    )
    File.chmod(0o755, executable)
    executable
  end

  def with_environment(values)
    previous = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  private

  def xml_attributes(attributes)
    return "" if attributes.empty?

    " " + attributes.map do |name, value|
      "#{name}=\"#{CGI.escapeHTML(value.to_s)}\""
    end.join(" ")
  end
end

class Minitest::Test
  include CddlMapTestSupport
end
