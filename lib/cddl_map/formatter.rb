# frozen_string_literal: true

require "json"

module CddlMap
  module Formatter
    module_function

    def success(report, json: false)
      return JSON.pretty_generate({ "ok" => true, "result" => report }) if json

      accepted = report.fetch("examples").count { |example| example["outcome"] == "accepted" }
      rejected = report.fetch("examples").length - accepted
      lock = report.fetch("lock")
      [
        "OK: #{report.fetch('documents').length} document(s), " \
        "#{report.fetch('cddl_blocks')} CDDL block(s), " \
        "#{report.fetch('examples').length} EDN example(s)",
        "examples: #{accepted} accepted, #{rejected} rejected as expected",
        "lock: #{lock.fetch('status')} (#{lock.fetch('path')})"
      ].join("\n")
    end

    def failure(error, json: false)
      return JSON.pretty_generate({ "ok" => false, "error" => error.to_h }) if json

      lines = ["error [#{error.code}]: #{error.message}"]
      details = error.details
      scalar_details = details.reject do |key, value|
        %i[stdout stderr differences selector undefined].include?(key) ||
          value.nil? || value == "" || value == []
      end
      scalar_details.each do |key, value|
        rendered = key == :command && value.is_a?(Array) ? value.join(" ") : value
        lines << "  #{key}: #{rendered}"
      end
      lines << "  selector: #{JSON.generate(details[:selector])}" if details[:selector]
      Array(details[:differences]).each { |difference| lines << "  drift: #{difference}" }
      Array(details[:undefined]).each { |undefined| lines << "  #{undefined}" }
      append_output(lines, "cddlc stdout", details[:stdout])
      append_output(lines, "cddlc stderr", details[:stderr])
      lines.join("\n")
    end

    def append_output(lines, label, output)
      return if output.nil? || output.empty?

      lines << "  #{label}:"
      output.scrub.lines(chomp: true).each { |line| lines << "    #{line}" }
    end
    private_class_method :append_output
  end
end
