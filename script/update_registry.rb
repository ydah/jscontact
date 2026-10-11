# frozen_string_literal: true

require_relative "prepare_rfc_fixtures"
require_relative "../lib/jscontact"

module JSContactRegistry
  DIRECTORY = File.expand_path("../tmp/registry/sources", __dir__)
  MANIFEST_PATH = File.join(__dir__, "registry_sources.json")
  MANIFEST = JSON.parse(File.read(MANIFEST_PATH)).freeze
  BASIC_TYPES = %w[Boolean Id Int JCardProp Number PatchObject String UnsignedInt UTCDateTime].freeze
  STRING_TYPES = %w[NonEmptyString URI GeoURI Email LanguageTag Script Version VCardName CalendarScale CountryCode TimeZone MediaType].freeze
  # RFC 9553 sections 2.2.5 and 2.3.4 use Id where the current IANA table says String.
  REGISTRY_TYPE_DIFFERENCES = {
    %w[Title organizationId] => %w[Id String],
    %w[Card preferredLanguages] => ["Id[LanguagePref]", "String[LanguagePref]"]
  }.freeze

  module_function

  def prepare
    FileUtils.mkdir_p(DIRECTORY)
    MANIFEST.fetch("sources").each { |name, source| RFCFixtures.fetch(source, File.join(DIRECTORY, name)) }
  end

  def records(document, identifier)
    REXML::XPath.match(document, "//registry[@id='#{identifier}']/record")
  end

  def text(element, name)
    element.elements[name]&.text.to_s.strip
  end

  def signature(type)
    return "String" if STRING_TYPES.include?(type) || type.start_with?("Enum:")
    return "UnsignedInt" if %w[PositiveInt Preference Month Day].include?(type)
    return "String[Boolean]" if type == "Contexts" || type.start_with?("EnumMap:")
    return "String[String|String[]]" if type == "VCardParams"

    type.gsub("LanguageTag[", "String[").gsub("[True]", "[Boolean]")
  end

  def audit(directory = DIRECTORY, schema: JSContact::SCHEMA, enums: JSContact::ENUMS)
    document = REXML::Document.new(File.read(File.join(directory, "jscontact.xml")))
    errors = []
    versions = records(document, "jscontact-version").map { |record| "#{text(record, "major")}.#{text(record, "minor")}" }
    errors << "Version coverage changed: #{versions.inspect}" unless versions.sort == %w[1.0 2.0]
    records(document, "jscontact-types").each do |record|
      name = text(record, "value")
      next if text(record, "usage") == "reserved" || BASIC_TYPES.include?(name) || schema.key?(name)

      errors << "Missing type #{name}"
    end
    records(document, "jscontact-properties").each do |record|
      name = text(record, "name")
      context = text(record, "context")
      next if name == "extra" && context == "not applicable"

      contexts = context == "Any JSContact object" ? schema.keys : context.split(/\s*,\s*/)
      contexts.each do |type|
        definition = schema[type]
        if text(record, "usage") == "reserved"
          errors << "Missing reservation #{type}.#{name}" unless definition&.fetch("reserved", [])&.include?(name)
        elsif !(rule = definition&.dig("properties", name))
          errors << "Missing property #{type}.#{name}"
        elsif signature(rule.fetch("type")) != text(record, "type") &&
              REGISTRY_TYPE_DIFFERENCES[[type, name]] != [rule.fetch("type"), text(record, "type")]
          errors << "Type mismatch #{type}.#{name}: #{rule.fetch("type")} versus #{text(record, "type")}"
        end
      end
    end
    audit_enums(document, schema, enums, errors)
    scripts = File.read(File.join(directory, "language-subtag-registry.txt")).split(/^%%\s*$/).filter_map do |record|
      record[/^Subtag: (.+)$/, 1] if record.match?(/^Type: script$/)
    end
    scripts = scripts.reject { |script| script.include?("..") }.map(&:downcase).sort
    errors << "Registered script codes differ from data/enums.yml" unless scripts == enums.fetch("script", []).map(&:downcase).sort
    errors
  end

  def audit_enums(document, schema, enums, errors)
    REXML::XPath.match(document, "//registry[starts-with(@id, 'jscontact-enum-values-')]").each do |registry|
      title = text(registry, "title").gsub(/\s+/, " ")
      property, context = title.match(/for (\w+) \(Context: (.+)\)/).captures
      values = registry.get_elements("record").map { |record| text(record, "value") }
      context.split(/\s*,\s*/).each do |type|
        rule = schema.dig(type, "properties", property, "type").to_s
        enum = rule == "Contexts" ? "context" : rule.sub(/\AEnum(?:Map)?:/, "")
        missing = values - enums.fetch(enum, [])
        errors << "Missing enum values for #{type}.#{property}: #{missing.join(", ")}" unless missing.empty?
      end
    end
  end

  def run(refresh: false)
    unless refresh
      prepare
      errors = audit
      raise errors.join("\n") unless errors.empty?

      puts "IANA versions, properties, types, enumerations and script codes match the validation metadata."
      return
    end

    FileUtils.mkdir_p(File.dirname(DIRECTORY))
    Dir.mktmpdir("registry-review-", File.dirname(DIRECTORY)) do |directory|
      manifest = JSON.parse(File.read(MANIFEST_PATH))
      manifest.fetch("sources").each do |name, source|
        path = File.join(directory, name)
        success = system("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
                         "--retry", "3", "--connect-timeout", "10", "--max-time", "60", source.fetch("url"), "--output", path)
        raise "Download failed: #{source.fetch("url")}" unless success

        source["sha256"] = Digest::SHA256.file(path).hexdigest
      end
      errors = audit(directory)
      unless errors.empty?
        File.write(File.join(File.dirname(DIRECTORY), "review.txt"), "#{errors.join("\n")}\n")
        raise "Registry metadata needs review; see tmp/registry/review.txt\n#{errors.join("\n")}"
      end
      manifest["checked_on"] = Date.today.iso8601
      File.write(MANIFEST_PATH, "#{JSON.pretty_generate(manifest)}\n")
      FileUtils.mkdir_p(DIRECTORY)
      FileUtils.cp(Dir.glob(File.join(directory, "*")), DIRECTORY)
      puts "Reviewed registry source hashes updated; validation metadata is unchanged."
    end
  end
end

JSContactRegistry.run(refresh: ARGV.include?("--refresh")) if $PROGRAM_NAME == __FILE__
