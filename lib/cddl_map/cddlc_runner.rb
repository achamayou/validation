# frozen_string_literal: true

require "open3"
require "rbconfig"

module CddlMap
  class CddlcRunner
    UNDEFINED_PATTERN = /\A;;;\s+\*{3}\s+undefined:/
    REJECTION_PATTERN = /\A\s*---(?:\s|\z)/

    Result = Struct.new(
      :command, :stdout, :stderr, :exit_status,
      keyword_init: true
    ) do
      def success?
        exit_status.zero?
      end
    end

    def self.available?
      default_command
      true
    rescue Gem::Exception
      false
    end

    def self.default_command
      [
        RbConfig.ruby,
        Gem.bin_path("cddlc", "cddlc", "= 0.4.5")
      ]
    end

    def initialize(directory, command: nil, environment: {})
      @directory = directory
      @command = command || self.class.default_command
      @environment = environment
    rescue Gem::Exception => e
      raise Error.new(
        "cddlc 0.4.5 is not installed: #{e.message}",
        code: "cddlc_missing"
      )
    end

    def check_schema(schema, **context)
      result = invoke("-u", "-2", "-t", "cddl", schema)
      undefined = result.stdout.lines.grep(UNDEFINED_PATTERN).map(&:chomp)
      return result if result.success? && undefined.empty? && result.stderr.empty?

      raise Error.new(
        "cddlc rejected the staged CDDL schema",
        code: "cddlc_schema",
        **context,
        command: result.command,
        exit_status: result.exit_status,
        undefined: undefined,
        stdout: result.stdout,
        stderr: result.stderr
      )
    end

    def validate_example(schema:, example:, entry_rule:, expect:, **context)
      result = invoke("-2", "-s", entry_rule, "-d", example, schema)
      if result.success?
        if expect == "reject"
          raise Error.new(
            "example was accepted but the manifest expects rejection",
            code: "example_unexpected_accept",
            **context,
            command: result.command,
            exit_status: result.exit_status,
            stdout: result.stdout,
            stderr: result.stderr
          )
        end
        return "accepted"
      end

      if REJECTION_PATTERN.match?(result.stdout)
        if expect == "reject"
          return "rejected"
        end

        raise Error.new(
          "example did not validate against #{entry_rule}",
          code: "example_rejected",
          **context,
          command: result.command,
          exit_status: result.exit_status,
          stdout: result.stdout,
          stderr: result.stderr
        )
      end

      raise Error.new(
        "cddlc could not parse or validate the EDN example",
        code: "cddlc_example",
        **context,
        command: result.command,
        exit_status: result.exit_status,
        stdout: result.stdout,
        stderr: result.stderr
      )
    end

    private

    def invoke(*arguments)
      command = @command + arguments
      stdout, stderr, status = Open3.capture3(
        @environment.merge("CDDL_INCLUDE_PATH" => ".:"),
        *command,
        chdir: @directory
      )
      Result.new(
        command: command,
        stdout: stdout,
        stderr: stderr,
        exit_status: status.exitstatus || (128 + status.termsig)
      )
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error.new(
        "cannot execute cddlc: #{e.message}",
        code: "cddlc_execute",
        command: command
      )
    end
  end
end
