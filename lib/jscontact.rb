# frozen_string_literal: true

require "json"
require "yaml"
require "date"
require "uri"
require "tzinfo"
require_relative "jscontact/version"
require_relative "jscontact/errors"
require_relative "jscontact/types"
require_relative "jscontact/validator"
require_relative "jscontact/model"
require_relative "jscontact/patch_object"
require_relative "jscontact/localization"

JSContact = Jscontact unless defined?(JSContact)

module Jscontact
  class << self
    # Parses one Card, preserving unknown fields and its original JSContact version.
    def parse(source, strict: true, **limits)
      raise ParseError, "JSON input must be a String" unless source.is_a?(String)

      Validator.new(**limits)
      options = DEFAULT_LIMITS.merge(limits)
      raise LimitError, "input exceeds max_input_size" if source.bytesize > options[:max_input_size]

      data = JSON.parse(source, allow_duplicate_key: false, max_nesting: options[:max_depth])
      Card.new(data, strict: strict, **limits)
    rescue JSON::NestingError => e
      raise LimitError, e.message
    rescue JSON::ParserError, EncodingError => e
      raise ParseError, e.message
    end

    # Upgrades a copy; a parsed 1.0 Card otherwise remains 1.0 on serialization.
    def upgrade(card)
      card = Card.new(card) unless card.is_a?(Card)
      card.validate!
      data = card.to_h
      data["version"] = "2.0"
      Card.new(data, **card.limits).validate!
    end
  end
end
