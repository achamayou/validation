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

    def self.import_stem(name)
      module_stem(name).sub(/\Am-/, "i-")
    end

    def initialize(directory, manifest, selections)
      @directory = directory
      @manifest = manifest
      @selections = selections
      @modules = {}
    end

    def stage
      stage_modules
      stage_import_modules
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

    def stage_import_modules
      @manifest.cddl.each_key do |name|
        body = dependency_order([name]).map do |dependency|
          ";# include #{@modules.fetch(dependency)}\n"
        end.join
        write("#{self.class.import_stem(name)}.cddl", body)
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
      includes = dependency_order(roots)
      body = includes.map do |name|
        ";# include #{@modules.fetch(name)}\n"
      end.join
      body << import_order(includes).map { |spec| import_directive(spec) }.join
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

    def import_order(includes)
      included = includes.to_h { |name| [name, true] }
      visiting = {}
      path = []
      order = []
      visit = lambda do |imported|
        name = imported.cddl
        return if included.key?(name)

        if visiting[name]
          start = path.index(name)
          cycle = path[start..] + [name]
          raise Error.new(
            "CDDL import cycle: #{cycle.join(' -> ')}",
            code: "manifest_import_cycle",
            cycle: cycle
          )
        end

        visiting[name] = true
        path << name
        order << imported
        dependency_order([name]).each do |dependency|
          @manifest.cddl.fetch(dependency).imports.each { |nested| visit.call(nested) }
        end
        path.pop
        visiting.delete(name)
      end
      includes.each do |name|
        @manifest.cddl.fetch(name).imports.each { |imported| visit.call(imported) }
      end
      order
    end

    def import_directive(spec)
      source = self.class.import_stem(spec.cddl)
      return ";# import #{source}\n" unless spec.rules

      ";# import #{spec.rules.join(', ')} from #{source}\n"
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
