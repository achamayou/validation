# frozen_string_literal: true

require "digest"

module CddlMap
  class Stager
    Staged = Struct.new(
      :directory, :modules, :cddl_schemas, :edn_schemas, :examples,
      keyword_init: true
    )

    def self.module_stem(name)
      slug = name.downcase.gsub(/[^a-z0-9]+/, "-").sub(/\A-+/, "").sub(/-+\z/, "")
      slug = "block" if slug.empty?
      "m-#{slug[0, 40]}-#{Digest::SHA256.hexdigest(name)[0, 10]}"
    end

    def initialize(directory, manifest, selections)
      @directory = directory
      @manifest = manifest
      @selections = selections
      @modules = {}
    end

    def stage
      stage_modules
      cddl_schemas = @manifest.cddl.keys.to_h do |name|
        [name, write_schema("schema-#{self.class.module_stem(name)}", [name])]
      end
      edn_schemas = @manifest.edn.to_h do |name, spec|
        schema =
          if spec.cddl.length == 1
            cddl_schemas.fetch(spec.cddl.first)
          else
            write_schema("schema-edn-#{self.class.module_stem(name)}", spec.cddl)
          end
        [name, schema]
      end
      examples = @manifest.edn.keys.to_h { |name| [name, stage_examples(name)] }

      Staged.new(
        directory: @directory,
        modules: @modules.freeze,
        cddl_schemas: cddl_schemas.freeze,
        edn_schemas: edn_schemas.freeze,
        examples: examples.freeze
      )
    end

    private

    def stage_modules
      @manifest.cddl.each_key do |name|
        stem = self.class.module_stem(name)
        matches = @selections.fetch("cddl:#{name}").fetch(:matches)
        if matches.length == 1
          write("#{stem}.cddl", matches.first.text)
        else
          parts = matches.each_with_index.map do |match, index|
            part = "#{stem}-part-#{format('%03d', index + 1)}"
            write("#{part}.cddl", match.text)
            part
          end
          write("#{stem}.cddl", parts.map { |part| ";# include #{part}\n" }.join)
        end
        @modules[name] = stem
      end
    end

    def stage_examples(name)
      stem = self.class.module_stem(name).sub(/\Am-/, "e-")
      @selections.fetch("edn:#{name}").fetch(:matches).each_with_index.map do |match, index|
        filename = "#{stem}-#{format('%03d', index + 1)}.edn"
        write(filename, match.text)
        filename
      end
    end

    def write_schema(stem, roots)
      filename = "#{stem}.cddl"
      body = dependency_order(roots).map do |name|
        ";# include #{@modules.fetch(name)}\n"
      end.join
      write(filename, body)
      filename
    end

    def dependency_order(roots)
      state = {}
      order = []
      visit = lambda do |name|
        return if state[name] == :done
        return if state[name] == :visiting

        state[name] = :visiting
        @manifest.cddl.fetch(name).depends_on.each { |dependency| visit.call(dependency) }
        state[name] = :done
        order << name
      end
      roots.each { |root| visit.call(root) }
      order
    end

    def write(filename, content)
      File.binwrite(File.join(@directory, filename), content)
    rescue SystemCallError => e
      raise Error.new(
        "cannot stage #{filename}: #{e.message}",
        code: "staging_io",
        path: filename
      )
    end
  end
end
