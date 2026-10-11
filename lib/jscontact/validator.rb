# frozen_string_literal: true

module Jscontact
  # Collects violations while treating configured resource limits as hard failures.
  class Validator
    KNOWN_NAMES = SCHEMA.values.flat_map { |definition| definition.fetch("properties").keys }.uniq.freeze

    def initialize(validate_localizations: true, **limits)
      unknown = limits.keys - DEFAULT_LIMITS.keys
      raise ArgumentError, "unknown limits: #{unknown.join(", ")}" unless unknown.empty?

      @limits = DEFAULT_LIMITS.merge(limits)
      @limits.each do |name, value|
        raise ArgumentError, "#{name} must be a nonnegative Integer" unless value.is_a?(Integer) && value >= 0
      end
      raise ArgumentError, "max_depth must be positive" unless @limits[:max_depth].positive?

      @validate_localizations = validate_localizations
      @errors = []
    end

    def validate(value, type: "Card", root: true)
      @errors = []
      inspect_json(value, "", 0, [])
      object(value, type, "", root: root)
      @errors
    end

    def validate_json(value, pointer: "")
      @errors = []
      inspect_json(value, pointer, 0, [])
      @errors
    end

    private

    def add(pointer, message)
      @errors << Violation.new(pointer: pointer, message: message)
    end

    def inspect_json(value, path, depth, ancestors)
      case value
      when Hash, Array
        raise LimitError.new("JSON nesting exceeds max_depth", pointer: path) if depth >= @limits[:max_depth]

        if ancestors.include?(value.object_id)
          add(path, "cyclic JSON data")
          return
        end
        next_ancestors = ancestors + [value.object_id]
        if value.is_a?(Hash)
          value.each do |key, item|
            unless key.is_a?(String) && unicode?(key)
              add(path, "JSON member names must be valid Unicode strings")
              next
            end
            inspect_json(item, Jscontact.pointer(path, key), depth + 1, next_ancestors)
          end
        else
          value.each_with_index { |item, index| inspect_json(item, Jscontact.pointer(path, index), depth + 1, next_ancestors) }
        end
      when String
        add(path, "string is not valid I-JSON Unicode") unless unicode?(value)
        check_data_uri_limit(value, path)
      when Integer
        add(path, "integer is outside the exact I-JSON range") unless Types.integer?(value)
      when Float
        add(path, "number must be finite") unless value.finite?
      when TrueClass, FalseClass, NilClass
        nil
      else
        add(path, "value is not JSON-compatible")
      end
    end

    def unicode?(value)
      return false unless value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?)

      value.each_codepoint.none? { |point| point.between?(0xD800, 0xDFFF) || point.between?(0xFDD0, 0xFDEF) || (point & 0xFFFF) >= 0xFFFE }
    end

    def check_data_uri_limit(value, path)
      return unless value.b.byteslice(0, 5)&.downcase == "data:"

      header, payload = value.b.split(",", 2)
      return unless payload

      payload = URI::DEFAULT_PARSER.unescape(payload)
      size = if header.downcase.end_with?(";base64")
               (payload.bytesize * 3 / 4) - [payload[/=+\z/].to_s.length, 2].min
             else
               payload.bytesize
             end
      raise LimitError.new("data URI exceeds max_data_uri_size", pointer: path) if size > @limits[:max_data_uri_size]
    end

    def object(value, type, path, root: false)
      unless value.is_a?(Hash)
        add(path, "expected #{type} object")
        return
      end
      fields = SCHEMA.fetch(type).fetch("properties")
      reserved = SCHEMA.fetch(type).fetch("reserved", [])
      add(Jscontact.pointer(path, "@type"), "expected @type #{type}") if (root || value.key?("@type")) && value["@type"] != type
      fields.each do |name, rule|
        required = rule["required"] || (type == "Card" && rule.fetch("required_versions", []).include?(value["version"]))
        add(Jscontact.pointer(path, name), "required property is missing") if required && !value.key?(name)
      end
      value.each do |name, item|
        next unless name.is_a?(String) && unicode?(name)

        location = Jscontact.pointer(path, name)
        if name.downcase == "extra" || reserved.any? { |entry| entry.casecmp?(name) }
          add(location, "#{name} is reserved")
        elsif fields.key?(name)
          check(item, fields[name].fetch("type"), location) unless name == "@type"
        elsif KNOWN_NAMES.any? { |known| known.casecmp?(name) }
          add(location, "property name has incorrect case or is not allowed in #{type}")
        elsif !Types.vendor?(name) && !name.match?(/\A(?:[a-z][A-Za-z0-9]*|@[A-Za-z0-9]+)\z/)
          add(location, "invalid property name")
        end
      end
      relationships(value, type, path)
    end

    def check(value, signature, path)
      return if value.is_a?(String) && !unicode?(value)

      if SCHEMA.key?(signature)
        object(value, signature, path)
      elsif signature.end_with?("[]")
        check_array(value, signature.delete_suffix("[]"), path)
      elsif (match = /\A(\w+)\[(.+)\]\z/.match(signature))
        check_map(value, match[1], match[2], path)
      elsif signature.start_with?("Enum:")
        check_enum(value, signature.delete_prefix("Enum:"), path)
      elsif signature.start_with?("EnumMap:")
        check_enum_map(value, signature.delete_prefix("EnumMap:"), path, true_only: true)
      elsif signature == "Contexts"
        check_enum_map(value, "context", path, true_only: false)
      elsif signature == "PartialDate|Timestamp"
        type = value.is_a?(Hash) ? value.fetch("@type", "PartialDate") : "PartialDate"
        if %w[PartialDate Timestamp].include?(type)
          object(value, type, path)
        else
          add(Jscontact.pointer(path, "@type"), "expected PartialDate or Timestamp")
        end
      elsif signature == "VCardParams"
        check_parameters(value, path)
      elsif signature == "JCardProp"
        check_jcard_property(value, path)
      elsif signature == "PatchObject"
        add(path, "expected PatchObject") unless value.is_a?(Hash)
        raise LimitError.new("patch count exceeds max_patches", pointer: path) if value.is_a?(Hash) && value.size > @limits[:max_patches]
      else
        add(path, "invalid #{signature} value") unless scalar?(value, signature)
      end
    end

    def check_array(value, signature, path)
      unless value.is_a?(Array)
        add(path, "expected an array")
        return
      end
      raise LimitError.new("array exceeds max_map_size", pointer: path) if value.size > @limits[:max_map_size]

      value.each_with_index { |item, index| check(item, signature, Jscontact.pointer(path, index)) }
    end

    def check_map(value, key_type, item_type, path)
      unless value.is_a?(Hash)
        add(path, "expected a map")
        return
      end
      raise LimitError.new("map exceeds max_map_size", pointer: path) if value.size > @limits[:max_map_size]

      value.each do |key, item|
        next unless key.is_a?(String) && unicode?(key)

        location = Jscontact.pointer(path, key)
        add(location, "invalid #{key_type} map key") unless scalar?(key, key_type)
        check(item, item_type, location)
      end
    end

    def check_enum(value, enum, path)
      return if value.is_a?(String) && (ENUMS.fetch(enum).include?(value) || Types.vendor?(value))

      add(path, "expected a registered or vendor-specific #{enum} value")
    end

    def check_enum_map(value, enum, path, true_only:)
      check_map(value, "String", true_only ? "True" : "Boolean", path)
      return unless value.is_a?(Hash)

      value.each_key { |key| check_enum(key, enum, Jscontact.pointer(path, key)) }
    end

    def check_parameters(value, path)
      unless value.is_a?(Hash)
        add(path, "expected vCard parameter map")
        return
      end
      value.each do |key, item|
        location = Jscontact.pointer(path, key)
        add(location, "invalid lowercase parameter name") unless key.is_a?(String) && key.match?(/\A[a-z0-9-]+\z/)
        unless item.is_a?(String) || (item.is_a?(Array) && !item.empty? && item.all?(String))
          add(location, "parameter must be a string or nonempty string array")
        end
      end
    end

    def check_jcard_property(value, path)
      unless value.is_a?(Array) && value.size >= 4
        add(path, "expected jCard property array")
        return
      end
      unless value[0].is_a?(String) && value[0].ascii_only? && value[0].match?(/\A[a-z0-9-]+\z/)
        add(Jscontact.pointer(path, 0), "invalid lowercase vCard property name")
      end
      check_parameters(value[1], Jscontact.pointer(path, 1))
      unless value[2].is_a?(String) && value[2].ascii_only? && value[2].match?(/\A[a-z0-9-]+\z/)
        add(Jscontact.pointer(path, 2), "invalid lowercase vCard value type")
        return
      end

      value.drop(3).each_with_index { |item, index| check_jcard_value(item, value[2], Jscontact.pointer(path, index + 3)) }
    end

    def check_jcard_value(value, type, path)
      return if value.is_a?(String) && !unicode?(value)

      if value.is_a?(Array) && %w[text unknown].include?(type)
        add(path, "structured jCard values must not be empty") if value.empty?
        value.each_with_index { |item, index| check_jcard_value(item, type, Jscontact.pointer(path, index)) }
        return
      end
      valid = case type
              when "boolean" then [true, false].include?(value)
              when "integer" then Types.integer?(value)
              when "float" then (value.is_a?(Integer) || value.is_a?(Float)) && value.finite?
              when "uri" then Types.uri?(value)
              when "language-tag" then Types.language_tag?(value)
              when "text", "unknown" then value.is_a?(String) && !value.match?(/[\x00-\x08\x0B-\x1F\x7F]/)
              when "date", "time", "date-time", "date-and-or-time", "timestamp", "utc-offset"
                Types.jcard_temporal?(value, type)
              else true # Unknown registered value types must survive round trips.
              end
      add(path, "invalid jCard #{type} value") unless valid
    end

    def scalar?(value, signature)
      case signature
      when "String" then value.is_a?(String)
      when "NonEmptyString" then value.is_a?(String) && !value.empty?
      when "Boolean" then [true, false].include?(value)
      when "True" then value == true
      when "Int" then Types.integer?(value)
      when "UnsignedInt" then Types.integer?(value, minimum: 0)
      when "PositiveInt" then Types.integer?(value, minimum: 1)
      when "Preference" then Types.integer?(value, minimum: 1, maximum: 100)
      when "Month" then Types.integer?(value, minimum: 1, maximum: 12)
      when "Day" then Types.integer?(value, minimum: 1, maximum: 31)
      when "Id" then Types.id?(value)
      when "UTCDateTime" then Types.utc_date_time?(value)
      when "URI" then Types.uri?(value)
      when "GeoURI" then geo_uri?(value)
      when "Email" then Types.email?(value)
      when "LanguageTag" then Types.language_tag?(value)
      when "Script" then Types.script?(value)
      when "Version" then %w[1.0 2.0].include?(value)
      when "VCardName" then value.is_a?(String) && value.match?(/\A[A-Za-z0-9-]+\z/)
      when "CalendarScale" then value.is_a?(String) && (ENUMS["calendarScale"].include?(value) || Types.vendor?(value))
      when "CountryCode" then value.is_a?(String) && !TZInfo::Country.get(value.upcase).nil?
      when "TimeZone" then value.is_a?(String) && !TZInfo::Timezone.get(value).nil?
      when "MediaType" then value.is_a?(String) && value.match?(%r{\A[A-Za-z0-9!\#$&^_.+-]+/[A-Za-z0-9!\#$&^_.+-]+(?:\s*;[^\r\n]+)?\z})
      else false
      end
    rescue TZInfo::InvalidCountryCode, TZInfo::InvalidTimezoneIdentifier
      false
    end

    def geo_uri?(value)
      return false unless value.is_a?(String) && value.ascii_only?

      coordinates, *parameters = value.split(";", -1)
      match = /\Ageo:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)(?:,-?\d+(?:\.\d+)?)?\z/i.match(coordinates)
      return false unless match

      crs = "wgs84"
      parameters.each_with_index do |parameter, index|
        name, content = parameter.split("=", 2)
        return false unless name&.match?(/\A[A-Za-z0-9-]+\z/)

        case name.downcase
        when "crs"
          return false unless index.zero? && content&.match?(/\A[A-Za-z0-9-]+\z/)

          crs = content.downcase
        when "u"
          return false unless index == (parameters.first.downcase.start_with?("crs=") ? 1 : 0)
          return false unless content&.match?(/\A\d+(?:\.\d+)?\z/)
        else
          return false if content && !content.match?(/\A(?:[A-Za-z0-9_.!~*'()\[\]:&+$-]|%[0-9A-Fa-f]{2})+\z/)
        end
      end
      return true unless crs == "wgs84"

      match[1].match?(/\A-?\d{1,2}(?:\.\d+)?\z/) && match[2].match?(/\A-?\d{1,3}(?:\.\d+)?\z/) &&
        match[1].to_f.between?(-90, 90) && match[2].to_f.between?(-180, 180)
    end

    def relationships(value, type, path)
      case type
      when "Card"
        add(Jscontact.pointer(path, "members"), "members requires kind group") if value.key?("members") && value["kind"] != "group"
        @errors.concat(Localization.validate(value, **@limits)) if @validate_localizations && value["localizations"].is_a?(Hash) && defined?(Localization)
      when "Name", "Address" then components(value, type, path)
      when "Organization"
        alternatives(value, %w[name units], path)
        add(Jscontact.pointer(path, "units"), "units must not be empty") if value["units"].is_a?(Array) && value["units"].empty?
      when "SpeakToAs" then alternatives(value, %w[grammaticalGender pronouns], path)
      when "OnlineService" then alternatives(value, %w[uri user], path)
      when "Author"
        add(path, "author needs a property other than @type") if (value.keys - ["@type"]).empty?
      when "PartialDate" then partial_date(value, path)
      end
    end

    def alternatives(value, names, path)
      add(path, "at least one of #{names.join(", ")} is required") unless names.any? { |name| value.key?(name) }
    end

    def components(value, type, path)
      alternatives(value, type == "Name" ? %w[components full] : %w[components coordinates countryCode full timeZone], path)
      list = value["components"]
      if value.key?("defaultSeparator") && (value["isOrdered"] != true || !value.key?("components"))
        add(Jscontact.pointer(path, "defaultSeparator"), "requires ordered components")
      end
      if value["sortAs"].is_a?(Hash)
        value["sortAs"].each_key do |kind|
          next if list.is_a?(Array) && list.any? { |component| component.is_a?(Hash) && component["kind"] == kind }

          add(Jscontact.pointer(Jscontact.pointer(path, "sortAs"), kind), "sort key must name an existing component kind")
        end
        add(Jscontact.pointer(path, "sortAs"), "requires components") unless value.key?("components")
      end
      return unless list.is_a?(Array)

      component_path = Jscontact.pointer(path, "components")
      unless list.any? { |component| component.is_a?(Hash) && component["kind"] != "separator" }
        add(component_path, "at least one non-separator component is required")
      end
      list.each_with_index do |component, index|
        next unless component.is_a?(Hash)

        location = Jscontact.pointer(component_path, index)
        if component["kind"] == "separator"
          add(location, "separator requires ordered components") unless value["isOrdered"] == true
          add(location, "consecutive separators are forbidden") if index.positive? && list[index - 1].is_a?(Hash) && list[index - 1]["kind"] == "separator"
        end
        if component.key?("phonetic") && !value.key?("phoneticScript") && !value.key?("phoneticSystem")
          add(Jscontact.pointer(location, "phonetic"), "requires phoneticScript or phoneticSystem on its parent")
        end
      end
    end

    def partial_date(value, path)
      alternatives(value, %w[year month day], path)
      add(Jscontact.pointer(path, "month"), "month requires year or day") if value.key?("month") && !value.key?("year") && !value.key?("day")
      add(Jscontact.pointer(path, "day"), "day requires month") if value.key?("day") && !value.key?("month")
      year, month, day = value.values_at("year", "month", "day")
      return unless Types.integer?(month, minimum: 1, maximum: 12) && Types.integer?(day, minimum: 1, maximum: 31)
      return if year && !Types.integer?(year, minimum: 0)

      add(path, "invalid Gregorian calendar date") unless Date.valid_date?(year || 2000, month, day, Date::GREGORIAN)
    end
  end
end
