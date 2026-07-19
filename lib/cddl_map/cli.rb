# frozen_string_literal: true

require "optparse"

module CddlMap
  class CLI
    def self.start(arguments, stdout: $stdout, stderr: $stderr)
      new(arguments, stdout: stdout, stderr: stderr).run
    end

    def initialize(arguments, stdout:, stderr:)
      @arguments = arguments.dup
      @stdout = stdout
      @stderr = stderr
      @json = false
    end

    def run
      command = @arguments.shift
      case command
      when "validate"
        run_validate
      when "diagram"
        run_diagram
      when "--version", "-v"
        @stdout.puts VERSION
        0
      when "--help", "-h"
        @stdout.puts global_usage
        0
      when nil
        @stderr.puts global_usage
        2
      else
        @stderr.puts "error: unknown command #{command.inspect}"
        @stderr.puts global_usage
        2
      end
    rescue OptionParser::ParseError => e
      @stderr.puts "error: #{e.message}"
      2
    rescue Error => e
      output = Formatter.failure(e, json: @json)
      (@json ? @stdout : @stderr).puts output
      1
    end

    private

    def run_validate
      options = {
        locked: false,
        update_lock: false,
        lock_path: nil,
        cddlc: nil,
        help: false
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: cddl-map validate [options] MANIFEST"
        opts.on("--locked", "Require and verify the lockfile") { options[:locked] = true }
        opts.on("--update-lock", "Replace the lockfile after a successful run") { options[:update_lock] = true }
        opts.on("--lock PATH", "Use PATH instead of the default lockfile") { |path| options[:lock_path] = path }
        opts.on("--cddlc PATH", "Use a specific cddlc executable") { |path| options[:cddlc] = path }
        opts.on("--json", "Write one machine-readable JSON result") { @json = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
      end
      parser.parse!(@arguments)
      if options[:help]
        @stdout.puts parser
        return 0
      end
      unless @arguments.length == 1
        raise OptionParser::ParseError, "exactly one MANIFEST is required"
      end

      command = options[:cddlc] && [File.expand_path(options[:cddlc])]
      report = Validator.new(
        @arguments.first,
        lock_path: options[:lock_path],
        locked: options[:locked],
        update_lock: options[:update_lock],
        cddlc_command: command
      ).call
      @stdout.puts Formatter.success(report, json: @json)
      0
    end

    def run_diagram
      options = {
        output: nil,
        markdown: false,
        help: false
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: cddl-map diagram [options] MANIFEST"
        opts.on("-o", "--output PATH", "Write the diagram to PATH") { |path| options[:output] = path }
        opts.on("--markdown", "Wrap the Mermaid diagram in Markdown") { options[:markdown] = true }
        opts.on("-h", "--help", "Show this help") { options[:help] = true }
      end
      parser.parse!(@arguments)
      if options[:help]
        @stdout.puts parser
        return 0
      end
      unless @arguments.length == 1
        raise OptionParser::ParseError, "exactly one MANIFEST is required"
      end

      manifest = Manifest.load(@arguments.first)
      output = options[:markdown] ? Diagram.markdown(manifest) : Diagram.render(manifest)
      if options[:output]
        write_diagram(options[:output], output)
      else
        @stdout.write(output)
      end
      0
    end

    def write_diagram(path, output)
      File.binwrite(File.expand_path(path), output)
    rescue SystemCallError => e
      raise Error.new(
        "cannot write diagram #{path}: #{e.message}",
        code: "diagram_io",
        path: path
      )
    end

    def global_usage
      <<~USAGE.chomp
        Usage: cddl-map COMMAND [options]

        Commands:
          validate MANIFEST  extract and validate the declared CDDL and EDN blocks
          diagram MANIFEST   render the manifest wiring as a Mermaid flowchart

        Run `cddl-map COMMAND --help` for command options.
      USAGE
    end
  end
end
