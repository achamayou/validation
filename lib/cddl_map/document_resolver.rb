# frozen_string_literal: true

require "net/http"
require "openssl"
require "pathname"
require "timeout"
require "uri"

module CddlMap
  class DocumentResolver
    MAX_REDIRECTS = 5
    MAX_DOCUMENT_BYTES = 25 * 1024 * 1024

    ResolvedDocument = Struct.new(
      :id, :source, :content,
      keyword_init: true
    )

    def initialize(manifest)
      @manifest = manifest
    end

    def resolve_all
      @manifest.documents.transform_values { |spec| resolve(spec) }
    end

    private

    def resolve(spec)
      content, source =
        case spec.source_kind
        when "path"
          resolve_path(spec)
        when "rfc"
          url = "https://www.rfc-editor.org/rfc/rfc#{spec.source_value}.xml"
          [fetch(url), "rfc:#{spec.source_value}"]
        when "url"
          [fetch(spec.source_value), "url:#{spec.source_value}"]
        end

      ResolvedDocument.new(
        id: spec.id,
        source: source,
        content: content
      )
    end

    def resolve_path(spec)
      absolute = File.expand_path(spec.source_value, File.dirname(@manifest.path))
      [File.binread(absolute), "path:#{spec.source_value}"]
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      raise Error.new(
        "cannot read document #{spec.id} from #{spec.source_value}: #{e.message}",
        code: "document_io",
        document: spec.id,
        source: spec.source_value
      )
    end

    def fetch(url, redirects = 0)
      raise Error.new(
        "too many redirects while fetching #{url}",
        code: "document_http",
        source: url
      ) if redirects > MAX_REDIRECTS

      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTP) && uri.host
        raise Error.new(
          "document URL must use http or https: #{url}",
          code: "document_url",
          source: url
        )
      end

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "cddl-map/#{VERSION}"
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.is_a?(URI::HTTPS),
        open_timeout: 15,
        read_timeout: 45
      ) { |http| http.request(request) }

      case response
      when Net::HTTPSuccess
        body = response.body
        if body.bytesize > MAX_DOCUMENT_BYTES
          raise Error.new(
            "document at #{url} exceeds #{MAX_DOCUMENT_BYTES} bytes",
            code: "document_size",
            source: url,
            bytes: body.bytesize
          )
        end
        body
      when Net::HTTPRedirection
        location = response["location"]
        unless location
          raise Error.new(
            "redirect from #{url} has no Location header",
            code: "document_http",
            source: url,
            status: response.code.to_i
          )
        end
        fetch(URI.join(url, location).to_s, redirects + 1)
      else
        raise Error.new(
          "HTTP #{response.code} while fetching #{url}",
          code: "document_http",
          source: url,
          status: response.code.to_i
        )
      end
    rescue URI::InvalidURIError => e
      raise Error.new(
        "invalid document URL #{url}: #{e.message}",
        code: "document_url",
        source: url
      )
    rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise Error.new(
        "cannot fetch #{url}: #{e.message}",
        code: "document_http",
        source: url
      )
    end
  end
end
