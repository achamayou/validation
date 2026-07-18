# frozen_string_literal: true

require "json"
require "yaml"

files = Dir.glob("*.{cddl,edn}").sort.to_h { |path| [path, File.binread(path)] }
record = {
  "argv" => ARGV,
  "cwd" => Dir.pwd,
  "include_path" => ENV["CDDL_INCLUDE_PATH"],
  "files" => files
}
File.open(ENV.fetch("FAKE_CDDLC_LOG"), "ab") do |log|
  log.puts(JSON.generate(record))
end

if (data_index = ARGV.index("-d"))
  data = File.binread(ARGV.fetch(data_index + 1))
  if data.include?("MALFORMED")
    warn "*** can't parse #{data.inspect}"
    warn "*** Expected an EDN item"
    exit 1
  end
  if data.include?("REJECT")
    puts({ "matched" => false }.to_yaml)
    exit 1
  end

  warn "[true, #{data.inspect}]"
  exit 0
end

if files.values.any? { |content| content.include?("UNDEFINED_TRIGGER") }
  puts ";;; *** undefined: missing-rule"
end
warn "*** synthetic schema warning" if files.values.any? { |content| content.include?("SCHEMA_WARNING") }
puts File.binread(ARGV.last)
