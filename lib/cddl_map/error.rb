# frozen_string_literal: true

module CddlMap
  class Error < StandardError
    attr_reader :code, :details

    def initialize(message, code:, **details)
      super(message)
      @code = code
      @details = details.compact
    end

    def to_h
      {
        "code" => code,
        "message" => message,
        "details" => details.transform_keys(&:to_s)
      }
    end
  end
end
