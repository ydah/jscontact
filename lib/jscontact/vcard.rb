# frozen_string_literal: true

require_relative "../jscontact"
require "jcard_jcal"
require "digest/sha1"
require "time"
require_relative "vcard/structured"
require_relative "vcard/to_jscontact"
require_relative "vcard/from_jscontact"

module Jscontact
  # Optional RFC 9555 conversion, updated for RFC 9982's optional UID.
  module VCard
    # RFC 9555 §§2.4–2.13: scalar values in identifier maps.
    PROPERTIES = {
      "source" => %w[directories uri entry], "nickname" => %w[nicknames name],
      "photo" => %w[media uri photo], "email" => %w[emails address],
      "impp" => %w[onlineServices uri], "socialprofile" => %w[onlineServices uri],
      "lang" => %w[preferredLanguages language], "tel" => %w[phones number],
      "contact-uri" => %w[links uri contact], "logo" => %w[media uri logo],
      "title" => %w[titles name title], "role" => %w[titles name role],
      "expertise" => %w[personalInfo value expertise], "hobby" => %w[personalInfo value hobby],
      "interest" => %w[personalInfo value interest], "org-directory" => %w[directories uri directory],
      "note" => %w[notes note], "sound" => %w[media uri sound], "url" => %w[links uri],
      "key" => %w[cryptoKeys uri], "caladruri" => %w[schedulingAddresses uri],
      "caluri" => %w[calendars uri calendar], "fburl" => %w[calendars uri freeBusy],
      "pronouns" => ["speakToAs/pronouns", "pronouns"]
    }.each_value(&:freeze).freeze
    SCALARS = { "kind" => "kind", "uid" => "uid", "prodid" => "prodId", "language" => "language",
                "created" => "created", "rev" => "updated" }.freeze
    FEATURES = { "cell" => "mobile", "fax" => "fax", "main-number" => "main-number", "pager" => "pager",
                 "text" => "text", "textphone" => "textphone", "video" => "video", "voice" => "voice" }.freeze
    CONTEXTS = { "home" => "private", "work" => "work", "billing" => "billing", "delivery" => "delivery" }.freeze
    REGISTRY = JCard::Registry.default.dup.tap do |registry|
      %w[birthplace deathplace].each { |name| registry.register(name, type: "text", types: %w[text uri]) }
      registry.register("deathdate", type: "date-and-or-time", types: %w[date-and-or-time date date-time time text timestamp])
      %w[expertise hobby interest jsprop x-ablabel].each { |name| registry.register(name, type: "text") }
      %w[contact-uri org-directory].each { |name| registry.register(name, type: "uri") }
    end.freeze

    def self.to_jscontact(vcard_text, version: "2.0")
      raise ConversionError.new("unsupported JSContact version", pointer: "/version") unless %w[1.0 2.0].include?(version)

      cards = JCard.from_vcard(vcard_text, registry: REGISTRY)
      raise ConversionError, "expected exactly one vCard" unless cards.length == 1

      hash = ToJSContact.new(cards.first.to_a[1], version: version).convert
      if version == "1.0"
        warn "JSContact 1.0 conversion is deprecated; prefer version 2.0"
        hash["uid"] ||= stable_uid(vcard_text)
      end
      card = Card.new(hash)
      card.validate!
      card
    rescue JCardJCal::Error => e
      raise ConversionError.new(e.message, pointer: e.pointer || "")
    end

    def self.from_jscontact(card)
      card = Card.new(card) if card.is_a?(Hash)
      raise ConversionError, "expected a JSContact Card or object" unless card.is_a?(Card)

      card.validate!
      FromJSContact.new(card.to_h).convert
    rescue JCardJCal::Error => e
      raise ConversionError.new(e.message, pointer: e.pointer || "")
    end

    def self.stable_uid(source)
      bytes = Digest::SHA1.digest("jscontact-vcard\0#{source}").bytes.first(16)
      bytes[6] = (bytes[6] & 15) | 80
      bytes[8] = (bytes[8] & 63) | 128
      hex = bytes.pack("C*").unpack1("H*")
      "urn:uuid:#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end
    private_class_method :stable_uid
  end
end
