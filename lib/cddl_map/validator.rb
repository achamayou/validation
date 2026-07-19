# frozen_string_literal: true

require "tmpdir"

module CddlMap
  class Validator
    attr_reader :manifest_path, :lock_path

    def initialize(
      manifest_path,
      lock_path: nil,
      locked: false,
      update_lock: false,
      cddlc_command: nil,
      cddlc_environment: {}
    )
      @manifest_path = File.expand_path(manifest_path)
      @lock_path = File.expand_path(lock_path || Lockfile.default_path(@manifest_path))
      @locked = locked
      @update_lock = update_lock
      @cddlc_command = cddlc_command
      @cddlc_environment = cddlc_environment
    end

    def call
      reject_incompatible_options!
      manifest = Manifest.load(manifest_path)
      expected_lock = Lockfile.load(lock_path, required: @locked)
      documents = DocumentResolver.new(
        manifest,
        allow_unpinned_urls: @update_lock,
        lock_data: expected_lock
      ).resolve_all
      selections = extract(manifest, documents)
      actual_lock = Lockfile.build(manifest, documents, selections)
      Lockfile.verify!(expected_lock, actual_lock, path: lock_path) if expected_lock && !@update_lock

      example_results = validate_with_cddlc(manifest, selections)
      Lockfile.write(lock_path, actual_lock) if @update_lock

      {
        "manifest" => manifest_path,
        "documents" => documents.values.map do |document|
          {
            "id" => document.id,
            "source" => document.source,
            "sha256" => document.sha256
          }
        end,
        "cddl_blocks" => manifest.cddl.length,
        "examples" => example_results,
        "lock" => lock_status(expected_lock)
      }
    end

    private

    def reject_incompatible_options!
      return unless @locked && @update_lock

      raise Error.new(
        "--locked and --update-lock are mutually exclusive",
        code: "cli_options"
      )
    end

    def extract(manifest, documents)
      extractors = documents.transform_values { |document| Extractor.new(document) }
      selections = {}
      manifest.cddl.each do |name, spec|
        selections["cddl:#{name}"] = {
          document: spec.document,
          selector: spec.selector,
          matches: extractors.fetch(spec.document).select(
            spec.selector,
            selection: "cddl.#{name}"
          )
        }
      end
      manifest.edn.each do |name, spec|
        selections["edn:#{name}"] = {
          document: spec.document,
          selector: spec.selector,
          matches: extractors.fetch(spec.document).select(
            spec.selector,
            selection: "edn.#{name}"
          )
        }
      end
      selections
    end

    def validate_with_cddlc(manifest, selections)
      Dir.mktmpdir("cddl-map-") do |directory|
        staged = Stager.new(directory, manifest, selections).stage
        runner = CddlcRunner.new(
          directory,
          command: @cddlc_command,
          environment: @cddlc_environment
        )

        manifest.cddl.each do |name, spec|
          runner.check_schema(
            staged.cddl_schemas.fetch(name),
            document: spec.document,
            selection: "cddl.#{name}",
            selector: spec.selector
          )
        end
        manifest.edn.each do |name, spec|
          if spec.cddl.length > 1
            runner.check_schema(
              staged.edn_schemas.fetch(name),
              document: spec.document,
              selection: "edn.#{name}",
              selector: spec.selector
            )
          end
        end

        manifest.edn.flat_map do |name, spec|
          if spec.expect == "skip"
            next staged.examples.fetch(name).each_index.map do |index|
              {
                "set" => name,
                "index" => index + 1,
                "expected" => "skip",
                "outcome" => "skipped"
              }
            end
          end

          staged.examples.fetch(name).each_with_index.map do |example, index|
            outcome = runner.validate_example(
              schema: staged.edn_schemas.fetch(name),
              example: example,
              entry_rule: spec.entry_rule,
              expect: spec.expect,
              document: spec.document,
              selection: "edn.#{name}[#{index + 1}]",
              selector: spec.selector
            )
            {
              "set" => name,
              "index" => index + 1,
              "expected" => spec.expect,
              "outcome" => outcome
            }
          end
        end
      end
    end

    def lock_status(expected_lock)
      if @update_lock
        { "status" => "updated", "path" => lock_path }
      elsif expected_lock
        { "status" => "verified", "path" => lock_path }
      else
        { "status" => "absent", "path" => lock_path }
      end
    end
  end
end
