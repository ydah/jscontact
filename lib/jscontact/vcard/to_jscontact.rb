# frozen_string_literal: true

module Jscontact
  module VCard
    # Each conversion works on private state; registry and mapping tables are immutable.
    class ToJSContact
      def initialize(properties, version: "2.0")
        @properties = properties
        @card = { "@type" => "Card", "version" => version }
        @ids = {}
        @counters = Hash.new(0)
        @reserved = properties.filter_map { |prop| prop[1]["prop-id"] }
        @paths = {}.compare_by_identity
        @groups = {}
        @anniversaries = {}
        @scalar_seen = {}
        @labels = properties.select { |prop| prop[0] == "x-ablabel" }.to_h { |prop| [prop[1]["group"]&.downcase, prop[3]] }
      end

      def convert
        @properties.each_with_index do |prop, index|
          prop[1].each do |key, value|
            next unless %w[altid language phonetic script prop-id pref mediatype index level service-type username
                           author author-name created calscale label geo tz cc derived jscomps jsptr].include?(key)
            next if value.is_a?(String)

            raise ConversionError.new("#{key.upcase} must have a single value", pointer: "/vCardProps/#{index}/1/#{key}")
          end
        end
        language = @properties.find { |prop| prop[0] == "language" }&.[](3)
        unless language || @properties.any? { |prop| prop[0] == "fn" && !prop[1]["language"] }
          candidates = @properties.reject { |prop| prop[1]["phonetic"] }.filter_map { |prop| prop[1]["language"] }
          language = candidates.tally.max_by { |_, count| count }&.first
        end
        @card["language"] = normalize_language(language) if language
        groups = @properties.reject { |prop| %w[jsprop x-ablabel].include?(prop[0]) || prop[1]["phonetic"] }
                            .group_by { |prop| alternative_key(prop) }
        priority = { "org" => 0, "adr" => 0, "bday" => 1, "deathdate" => 1, "anniversary" => 1 }
        groups = groups.values.sort_by { |props| priority.fetch(props.first[0], 2) }
        alternatives = []
        groups.each do |props|
          primary = props.min_by { |prop| [language_rank(prop), prop[1].length] }
          path = convert_property(primary)
          @paths[primary] = path
          props.reject { |prop| prop.equal?(primary) }.each { |prop| alternatives << [prop, path] }
        end
        alternatives.each { |prop, path| convert_alternative(prop, path) }
        @properties.select { |prop| prop[1]["phonetic"] }.each { |prop| convert_phonetic(prop) }
        @properties.select { |prop| prop[0] == "x-ablabel" }.each do |prop|
          preserve(prop) unless prop[1]["group"] && @properties.any? do |other|
            other[0] != "x-ablabel" && other[1]["group"]&.downcase == prop[1]["group"]&.downcase &&
            @paths[other] && value_at(@card, @paths[other]).is_a?(Hash) && value_at(@card, @paths[other])["label"] == prop[3]
          end
        end
        # Anniversary requires a date; a place alone stays losslessly in vCardProps.
        @card.fetch("anniversaries", {}).delete_if do |id, anniversary|
          next false if anniversary["date"]

          @properties.each { |prop| preserve(prop) if @paths[prop] == ["anniversaries", id] }
          true
        end
        @card.delete("anniversaries") if @card["anniversaries"] && @card["anniversaries"].empty?
        apply_jsprops
        @card
      end

      private

      def alternative_key(prop)
        return [prop[0], "singleton"] if %w[fn n gramgender].include?(prop[0])
        return [prop[0], prop[1]["altid"]] if prop[1]["altid"]

        [prop.object_id]
      end

      def language_rank(prop)
        language = prop[1]["language"]
        return 0 unless language
        return 1 if normalize_language(language) == @card["language"]

        2
      end

      def normalize_language(language)
        raise ConversionError, "LANGUAGE must be a single value" unless language.is_a?(String)

        language.split("-").map.with_index do |part, index|
          if !index.zero? && part.length == 4
            part.capitalize
          elsif !index.zero? && part.length == 2
            part.upcase
          else
            part.downcase
          end
        end.join("-")
      end

      # RFC 9555 §2.3.11: localizations are atomic patches relative to the base Card.
      def convert_alternative(prop, path)
        return preserve(prop) unless path && prop[1]["language"]

        language = normalize_language(prop[1]["language"])
        return preserve(prop) if language == @card["language"]

        original = @card
        @card = copy(original)
        convert_property(prop, forced_path: path)
        translated = value_at(@card, path)
        @card = original
        changes = difference(value_at(original, path), translated, path.map { |token| token.gsub("~", "~0").gsub("/", "~1") }.join("/"))
        (@card["localizations"] ||= {})[language] ||= {}
        @card["localizations"][language].merge!(changes)
        @paths[prop] = path
      ensure
        @card = original if original
      end

      def convert_property(prop, forced_path: nil)
        name, params, type, value = prop
        return if params["derived"]&.casecmp?("true")
        return preserve(prop) if type == "unknown" && !REGISTRY[name]["type"].eql?("unknown")

        path = if PROPERTIES.key?(name)
                 convert_mapped(prop, forced_path)
               elsif SCALARS.key?(name)
                 return preserve(prop) if @scalar_seen[name] && !forced_path

                 @scalar_seen[name] = true
                 return preserve(prop) if name == "kind" && !ENUMS["cardKind"].include?(value.downcase)

                 key = SCALARS.fetch(name)
                 converted = %w[created rev].include?(name) ? timestamp(value) : value
                 return preserve(prop) if converted.nil?

                 converted = converted.downcase if name == "kind"
                 converted = normalize_language(converted) if name == "language"
                 @card[key] = converted
                 preserve(prop) unless (params.keys - %w[language altid derived]).empty?
                 [key]
               else
                 convert_special(prop, forced_path)
               end
        @paths[prop] = path if path.is_a?(Array)
        path
      end

      def convert_special(prop, forced_path)
        name, params, _type, value = prop
        case name
        when "fn"
          (@card["name"] ||= {})["full"] = value
          preserve(prop) unless (params.keys - %w[language altid derived]).empty?
          ["name"]
        when "n"
          object = Structured.read(value, params, name: true)
          object = parameters(object, prop, object["isOrdered"] ? %w[jscomps sort-as] : %w[sort-as])
          (@card["name"] ||= {}).merge!(object)
          ["name"]
        when "gramgender"
          return preserve(prop) unless ENUMS["gender"].include?(value.downcase)

          object = parameters({ "grammaticalGender" => value.downcase }, prop, common: false)
          (@card["speakToAs"] ||= {}).merge!(object)
          ["speakToAs"]
        when "org" then convert_organization(prop, forced_path)
        when "adr", "geo", "tz" then convert_address(prop, forced_path)
        when "bday", "birthplace", "deathdate", "deathplace", "anniversary" then convert_anniversary(prop, forced_path)
        when "member", "categories"
          return preserve(prop) if name == "member" && !@properties.find { |item| item[0] == "kind" }&.[](3)&.casecmp?("group")

          key = name == "member" ? "members" : "keywords"
          prop[3..].each { |item| (@card[key] ||= {})[item] = true }
          preserve(prop) unless (params.keys - %w[pref]).empty?
          [key]
        when "related"
          convert_relation(prop)
        else preserve(prop)
        end
      end

      def convert_relation(prop)
        _, params, _, value = prop
        known, unknown = parameter_values(params["type"]).partition { |entry| ENUMS["relation"].include?(entry.downcase) }
        object = parameters({ "relation" => known.to_h { |entry| [entry.downcase, true] } }, prop, %w[type], common: false)
        (object["vCardParams"] ||= {})["type"] = unknown.length == 1 ? unknown.first : unknown unless unknown.empty?
        map = @card["relatedTo"] ||= {}
        if (previous = map[value])
          previous["relation"].merge!(object["relation"])
          old_params = previous.fetch("vCardParams", {})
          new_params = object.fetch("vCardParams", {})
          if new_params.any? { |key, item| old_params.key?(key) && old_params[key] != item }
            preserve(prop)
          elsif !new_params.empty?
            previous["vCardParams"] = old_params.merge(new_params)
          end
        else
          map[value] = object
        end
        ["relatedTo", value]
      end

      def convert_mapped(prop, forced_path)
        name, params, type, value = prop
        map, key, kind = PROPERTIES.fetch(name)
        return preserve(prop) if key == "uri" && type != "uri" && name != "socialprofile"

        key = "user" if name == "socialprofile" && type != "uri"
        path = forced_path || (map.split("/") + [identifier(map, prop)])
        object = { key => value }
        object["kind"] = kind if kind
        object["vCardName"] = "impp" if name == "impp"
        consumed = []
        case name
        when "impp", "socialprofile"
          { "service-type" => "service", "username" => "user" }.each do |parameter, property|
            object[property] = params[parameter] if params[parameter]
            consumed << parameter
          end
        when "note"
          if params["created"] && (created = timestamp(params["created"], compact: true))
            object["created"] = created
            consumed << "created"
          end
          author = { "name" => params["author-name"], "uri" => params["author"] }.compact
          object["author"] = author unless author.empty?
          consumed += %w[author author-name]
        when "expertise", "hobby", "interest"
          if params["level"]
            level = params["level"].downcase
            object["level"] = name == "expertise" ? { "beginner" => "low", "average" => "medium", "expert" => "high" }.fetch(level, level) : level
          end
          consumed << "level"
        when "title", "role"
          organizations = @groups[params["group"]&.downcase]
          object["organizationId"] = organizations.first if params["group"] && organizations&.length == 1
        end
        if %w[expertise hobby interest org-directory].include?(name) && params["index"]
          object["listAs"] = integer(params["index"], "INDEX")
          consumed << "index"
        end
        object = parameters(object, prop, consumed)
        set_at(path, object)
        # A comma-separated NICKNAME contains independent nicknames (RFC 6350 §6.2.3).
        if name == "nickname"
          prop[4..].each do |nickname|
            set_at(map.split("/") + [identifier(map, [name, {}, type, nickname])], object.merge("name" => nickname))
          end
        end
        path
      end

      def convert_organization(prop, forced_path)
        _, params, _, values = prop
        values = Array(values)
        object = {}
        object["name"] = values.first unless values.first.to_s.empty?
        object["units"] = values.drop(1).map { |value| { "name" => value } } if values.length > 1
        sort = Array(params["sort-as"])
        object["sortAs"] = sort.first if sort.first && !sort.first.empty?
        object.fetch("units", []).each_with_index { |unit, i| unit["sortAs"] = sort[i + 1] if sort[i + 1] && !sort[i + 1].empty? }
        path = forced_path || ["organizations", identifier("organizations", prop)]
        object = parameters(object, prop, %w[sort-as])
        set_at(path, object)
        (@groups[params["group"]&.downcase] ||= []) << path.last if params["group"] && !forced_path
        path
      end

      # RFC 9555 §2.8.3: grouped and ungrouped geographic properties share an address.
      def convert_address(prop, forced_path)
        name, params, type, value = prop
        group = params["group"]&.downcase
        grouped = @properties.any? { |item| %w[adr geo tz].include?(item[0]) && item[1]["group"] }
        related = (@properties.find { |item| %w[adr geo tz].include?(item[0]) && item[1]["group"]&.downcase == group && @paths[item] } if group || grouped)
        path = forced_path || (related && @paths[related]) || ["addresses", identifier("addresses", prop)]
        object = case name
                 when "adr"
                   Structured.read(value, params, name: false).tap do |address|
                     { "label" => "full", "geo" => "coordinates", "cc" => "countryCode" }.each do |parameter, property|
                       address[property] = params[parameter] if params[parameter]
                     end
                     address["timeZone"] = timezone(params["tz"], "text") if params["tz"]
                   end
                 when "geo" then { "coordinates" => value }
                 when "tz"
                   zone = timezone(value, type)
                   return preserve(prop) unless zone

                   { "timeZone" => zone }
                 end
        object = parameters(object, prop, %w[label geo tz cc] + (object["isOrdered"] ? %w[jscomps] : []))
        set_at(path, (value_at(@card, path) || {}).merge(object))
        path
      end

      def timezone(value, type)
        return value if type == "text" && !value.match?(/\A[+-]\d{2}:?\d{2}\z/)
        return unless type == "utc-offset" || value.match?(/\A[+-]\d{2}:?\d{2}\z/)

        match = /\A([+-])(\d{2}):?00\z/.match(value)
        return unless match

        hours = match[2].to_i * (match[1] == "-" ? -1 : 1)
        return unless (-12..14).cover?(hours)
        return "Etc/UTC" if hours.zero?

        "Etc/GMT#{hours.positive? ? "-" : "+"}#{hours.abs}"
      end

      # RFC 9555 §§2.2.2 and 2.5.1: dates and places merge by anniversary kind.
      def convert_anniversary(prop, forced_path)
        name, params, type, value = prop
        kind = { "bday" => "birth", "birthplace" => "birth", "deathdate" => "death", "deathplace" => "death", "anniversary" => "wedding" }.fetch(name)
        converted = if name.end_with?("place")
                      return preserve(prop) unless type == "text" || (type == "uri" && value.start_with?("geo:"))

                      { "place" => { type == "uri" ? "coordinates" : "full" => value } }
                    else
                      # vCard dates use CALSCALE; JSContact date numbers always use Gregorian.
                      # RFC 6350 §5.8 requires ignoring calendars we cannot interpret.
                      return preserve(prop) if params["calscale"] && !params["calscale"].casecmp?("gregorian")

                      date = anniversary_date(value, type)
                      return preserve(prop) unless date

                      date["calendarScale"] = params["calscale"].downcase if params["calscale"] && date["@type"] != "Timestamp"
                      { "date" => date }
                    end
        path = forced_path || @anniversaries[kind] || ["anniversaries", identifier("anniversaries", prop)]
        object = value_at(@card, path) || { "kind" => kind }
        return preserve(prop) if converted.keys.any? { |key| object.key?(key) } && !forced_path

        if name.end_with?("place")
          converted["place"] = parameters(converted["place"], prop, common: false)
          (converted["place"]["vCardParams"] ||= {})["prop-id"] = params["prop-id"] if params["prop-id"] && params["prop-id"] != path.last
          object = object.merge(converted)
        else
          consumed = converted["date"]["@type"] == "Timestamp" ? [] : %w[calscale]
          object = parameters(object.merge(converted), prop, consumed, common: false)
        end
        @anniversaries[kind] = path
        set_at(path, object)
        path
      end

      def anniversary_date(value, type)
        return unless %w[date date-and-or-time date-time timestamp].include?(type)
        return { "@type" => "Timestamp", "utc" => timestamp(value) } if /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}(?::\d{2})?)\z/.match?(value)

        match = /\A(?:(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?|--(\d{2})-(\d{2}))\z/.match(value)
        return unless match

        { "year" => match[1]&.to_i, "month" => (match[2] || match[4])&.to_i, "day" => (match[3] || match[5])&.to_i }.compact
      end

      # RFC 9555 §2.3: only parameters with a counterpart leave vCardParams.
      def parameters(object, prop, consumed = [], common: true)
        name, params = prop
        remaining = params.except(*(%w[prop-id altid language derived] + consumed))
        fields = target_fields(name)
        if common
          object["pref"] = integer(remaining.delete("pref"), "PREF") if remaining["pref"] && fields.key?("pref")
          object["mediaType"] = remaining.delete("mediatype") if remaining["mediatype"] && fields.key?("mediaType")
          types = parameter_values(remaining.delete("type"))
          leftovers = []
          types.each do |type|
            lower = type.downcase
            if fields.key?("contexts") && CONTEXTS.key?(lower) && (%w[home work].include?(lower) || name == "adr")
              (object["contexts"] ||= {})[CONTEXTS.fetch(lower)] = true
            elsif name == "tel" && FEATURES.key?(lower)
              (object["features"] ||= {})[FEATURES.fetch(lower)] = true
            else
              leftovers << type
            end
          end
          remaining["type"] = leftovers.length == 1 ? leftovers.first : leftovers unless leftovers.empty?
        end
        object["label"] = @labels[params["group"]&.downcase] if fields.key?("label") && params["group"] && @labels[params["group"]&.downcase]
        object["vCardParams"] = remaining unless remaining.empty?
        object
      end

      def target_fields(name)
        map = PROPERTIES[name]&.first
        type = if map == "speakToAs/pronouns"
                 "Pronouns"
               elsif map
                 SCHEMA["Card"]["properties"][map]["type"][/\[(\w+)\]/, 1]
               else
                 { "n" => "Name", "org" => "Organization", "adr" => "Address", "geo" => "Address", "tz" => "Address",
                   "related" => "Relation", "gramgender" => "SpeakToAs" }.fetch(name, "Anniversary")
               end
        SCHEMA.fetch(type).fetch("properties")
      end

      def integer(value, parameter)
        raise ConversionError, "#{parameter} must be an integer" unless value.is_a?(String) && /\A\d+\z/.match?(value)

        value.to_i
      end

      def timestamp(value, compact: false)
        value = JCardJCal::ValueTypes.from_text(value, "timestamp", format: :vcard) if compact
        return unless value.match?(/(?:Z|[+-]\d{2}(?::\d{2})?)\z/)

        # Convert the minute separately because Ruby Time normalizes leap seconds.
        minute = Time.iso8601("#{value[0, 17]}00#{value[19..]}").utc
        "#{minute.strftime("%Y-%m-%dT%H:%M:")}#{value[17, 2]}Z"
      rescue ArgumentError
        raise ConversionError, "invalid vCard timestamp"
      end

      def parameter_values(value)
        Array(value).flat_map { |item| item.split(",") }
      end

      def identifier(map, prop)
        name, params = prop
        key = [map, name, params["altid"] || prop.object_id]
        return @ids[key] if @ids[key]

        explicit = params["prop-id"]
        if explicit
          raise ConversionError, "PROP-ID is not a JSContact identifier" unless explicit.is_a?(String) && /\A[A-Za-z0-9_-]{1,255}\z/.match?(explicit)
          raise ConversionError, "duplicate PROP-ID in #{map}" if value_at(@card, map.split("/") + [explicit])

          return @ids[key] = explicit
        end
        loop do
          @counters[map] += 1
          candidate = "#{map.delete("/")}#{@counters[map]}"
          return @ids[key] = candidate unless @reserved.include?(candidate)
        end
      end

      def convert_phonetic(prop)
        name, params, _, values = prop
        return preserve(prop) unless %w[n adr].include?(name)

        base = @properties.find { |item| item[0] == name && !item[1]["phonetic"] && item[1]["altid"] == params["altid"] }
        path = base && @paths[base]
        return preserve(prop) unless path

        object = copy(value_at(@card, path))
        object["phoneticSystem"] = params["phonetic"] unless params["phonetic"] == "script"
        object["phoneticScript"] = params["script"] if params["script"]
        phonetic = Structured.read(values, params, name: name == "n").fetch("components", []).group_by { |item| item["kind"] }
        object.fetch("components", []).each do |component|
          match = phonetic[component["kind"]]&.shift
          component["phonetic"] = match["value"] if match
        end
        unmapped_params = params.any? do |key, value|
          !%w[altid language phonetic script].include?(key) && base[1][key] != value
        end
        preserve(prop) if unmapped_params || phonetic.values.any? { |components| !components.empty? }
        language = params["language"] && normalize_language(params["language"])
        if language && language != @card["language"]
          changes = difference(value_at(@card, path), object, path.map { |token| token.gsub("~", "~0").gsub("/", "~1") }.join("/"), arrays: true)
          ((@card["localizations"] ||= {})[language] ||= {}).merge!(changes)
        else
          set_at(path, object)
        end
      end

      # RFC 9555 §3.2.1: apply all JSPROP values together, after regular properties.
      def apply_jsprops
        patches = {}
        @properties.select { |prop| prop[0] == "jsprop" }.each do |prop|
          pointer = prop[1]["jsptr"]
          raise ConversionError, "JSPROP requires a single JSPTR parameter" unless pointer.is_a?(String)

          pointer = pointer.delete_prefix("/")
          raise ConversionError, "duplicate JSPTR" if patches.key?(pointer)

          cursor = @card
          pointer.split("/", -1).each do |token|
            raise ConversionError, "JSPTR must not reference an array" if cursor.is_a?(Array)

            cursor = cursor.is_a?(Hash) ? cursor[token.gsub("~1", "/").gsub("~0", "~")] : nil
          end
          patches[pointer] = JSON.parse(prop[3], allow_duplicate_key: false)
          raise ConversionError, "JSPROP JSON must not contain insignificant whitespace" if prop[3].gsub(/"(?:\\.|[^"\\])*"/m, "").match?(/[ \t\r\n]/)
        rescue JSON::ParserError => e
          raise ConversionError, "invalid JSPROP JSON: #{e.message}"
        end
        @card = PatchObject.new(patches).apply(@card) unless patches.empty?
      end

      def preserve(prop)
        (@card["vCardProps"] ||= []) << copy(prop)
        nil
      end

      def value_at(object, path)
        path.reduce(object) { |cursor, token| cursor.is_a?(Hash) ? cursor[token] : nil }
      end

      def set_at(path, value)
        object = path[0...-1].reduce(@card) { |cursor, token| cursor[token] ||= {} }
        object[path.last] = value
      end

      def copy(value) = Jscontact.deep_copy(value)

      def difference(before, after, path, arrays: false)
        if before.is_a?(Hash) && after.is_a?(Hash)
          (before.keys | after.keys).each_with_object({}) do |key, result|
            result.merge!(difference(before[key], after[key], "#{path}/#{key.gsub("~", "~0").gsub("/", "~1")}", arrays: arrays))
          end
        elsif arrays && before.is_a?(Array) && after.is_a?(Array) && before.length == after.length
          before.each_index.with_object({}) { |index, result| result.merge!(difference(before[index], after[index], "#{path}/#{index}", arrays: arrays)) }
        elsif before != after
          { path => after }
        else
          {}
        end
      end
    end
  end
end
