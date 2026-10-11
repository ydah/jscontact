# frozen_string_literal: true

module Jscontact
  module VCard
    # RFC 9555 §3: native properties first, then JSPROP for unrepresentable data.
    class FromJSContact
      def initialize(card)
        @card = card
        @properties = []
        @raw = card.fetch("vCardProps", [])
        @raw.each_with_index do |property, index|
          JCard::Property.new(property, registry: REGISTRY, pointer: "/vCardProps/#{index}")
        end
      end

      def convert
        build_properties
        build_localizations
        represented = ToJSContact.new(@properties, version: @card.fetch("version")).convert
        # Arrays must be replaced as a whole: JSPTR may not reference array elements.
        difference(represented, @card).each do |pointer, value|
          @properties << ["jsprop", { "jsptr" => pointer }, "text", Jscontact.generate_json(value)]
        end
        properties = @properties.map { |property| JCard::Property.new(property, registry: REGISTRY) }
        quote_pointers(JCard::Card.new("vcard", properties, registry: REGISTRY).to_vcard)
      end

      def build_properties
        add("version", {}, "text", "4.0")
        SCALARS.each do |vcard_name, json_name|
          next unless @card.key?(json_name)

          type = REGISTRY[vcard_name]["type"]
          type = "text" if vcard_name == "uid" && !uri?(@card[json_name])
          value = @card[json_name]
          value = value.sub(/\.\d+Z\z/, "Z") if %w[created rev].include?(vcard_name)
          add(vcard_name, {}, type, value)
        end
        build_name(@card.fetch("name", {}))
        build_maps
        build_organizations
        build_addresses
        build_anniversaries
        build_speak_to_as
        @card.fetch("members", {}).each_key { |uid| add("member", {}, "uri", uid) if uri?(uid) }
        keywords = @card.fetch("keywords", {}).keys
        add("categories", {}, "text", *keywords) unless keywords.empty?
        @card.fetch("relatedTo", {}).each do |uid, relation|
          params = relation.fetch("vCardParams", {}).dup
          types = Array(params.delete("type")) + relation.fetch("relation", {}).keys.select { |kind| ENUMS["relation"].include?(kind) }
          params["type"] = types.uniq unless types.empty?
          add("related", params, uri?(uid) ? "uri" : "text", uid)
        end
        @properties.concat(@raw.reject { |prop| prop[0] == "version" })
        @properties
      end

      private

      def build_name(name)
        if name.key?("full")
          add("fn", {}, "text", name["full"])
        else
          add("fn", { "derived" => "TRUE" }, "text", Structured.full_name(name))
        end
        add("fn", { "derived" => "TRUE" }, "text", "") unless @properties.any? { |prop| prop[0] == "fn" } || @raw.any? { |prop| prop[0] == "fn" }
        return unless name["components"] || name["sortAs"]

        values, params = Structured.write(name, name: true)
        params = name.fetch("vCardParams", {}).merge(params)
        build_phonetic("n", name, params) if add("n", params, "text", values)
      end

      def build_maps
        PROPERTIES.values.map(&:first).uniq.each do |map|
          next if map == "speakToAs/pronouns"

          @card.fetch(map, {}).each do |id, object|
            name = property_name(map, object)
            next unless name

            _, key = PROPERTIES.fetch(name)
            key = "user" if name == "socialprofile" && !object["uri"]
            next unless object.key?(key)

            type = REGISTRY[name]["type"]
            type = "text" if name == "socialprofile" && key == "user"
            type = uri?(object[key]) ? "uri" : "text" if name == "tel"
            params = common_params(object, id)
            case name
            when "impp", "socialprofile"
              params["service-type"] = object["service"] if object["service"]
              params["username"] = object["user"] if object["user"] && key != "user"
            when "note"
              params["author-name"] = object.dig("author", "name") if object.dig("author", "name")
              params["author"] = object.dig("author", "uri") if object.dig("author", "uri")
              params["created"] = compact_timestamp(object["created"]) if object["created"]
            when "expertise", "hobby", "interest"
              if object["level"]
                params["level"] = if name == "expertise"
                                    { "low" => "beginner", "medium" => "average", "high" => "expert" }.fetch(object["level"], object["level"])
                                  else
                                    object["level"]
                                  end
              end
              params["index"] = object["listAs"].to_s if object["listAs"]
            when "org-directory"
              params["index"] = object["listAs"].to_s if object["listAs"]
            when "title", "role"
              if object["organizationId"] && @card.fetch("organizations", {}).key?(object["organizationId"])
                params["group"] = organization_group(object["organizationId"])
              end
            end
            add(name, params, type, object[key])
            add_label(object, params)
          end
        end
      end

      def property_name(map, object)
        case map
        when "onlineServices"
          object["vCardName"]&.casecmp?("impp") ? "impp" : "socialprofile"
        when "titles" then { "title" => "title", "role" => "role" }[object.fetch("kind", "title")]
        when "media" then %w[photo logo sound].find { |kind| object["kind"] == kind }
        when "personalInfo" then %w[expertise hobby interest].find { |kind| object["kind"] == kind }
        when "directories" then { "entry" => "source", "directory" => "org-directory" }[object["kind"]]
        when "calendars" then { "calendar" => "caluri", "freeBusy" => "fburl" }[object["kind"]]
        when "links" then object["kind"] == "contact" ? "contact-uri" : "url"
        else PROPERTIES.find { |_, definition| definition.first == map }&.first
        end
      end

      def build_organizations
        @card.fetch("organizations", {}).each do |id, object|
          units = object.fetch("units", [])
          values = [object.fetch("name", "")] + units.map { |unit| unit["name"] }
          sort = [object.fetch("sortAs", "")] + units.map { |unit| unit.fetch("sortAs", "") }
          params = common_params(object, id)
          params["sort-as"] = sort if sort.any? { |value| !value.empty? }
          params["group"] = organization_group(id) if @card.fetch("titles", {}).values.any? { |title| title["organizationId"] == id }
          add("org", params, "text", values.length == 1 ? values.first : values)
          add_label(object, params)
        end
      end

      def organization_group(id)
        object = @card["organizations"][id]
        object.dig("vCardParams", "group") || "org#{@card["organizations"].keys.index(id) + 1}"
      end

      def build_addresses
        @card.fetch("addresses", {}).each do |id, object|
          values, structured_params = Structured.write(object, name: false)
          params = common_params(object, id).merge(structured_params)
          { "full" => "label", "coordinates" => "geo", "timeZone" => "tz", "countryCode" => "cc" }.each do |key, parameter|
            params[parameter] = object[key] if object[key]
          end
          if add("adr", params, "text", values)
            add_label(object, params)
            build_phonetic("adr", object, params)
          end
        end
      end

      def build_phonetic(name, object, params)
        return unless object.fetch("components", []).any? { |component| component["phonetic"] }

        params["altid"] ||= params.fetch("prop-id", "name")
        # add copies its arguments so the base property needs the same ALTID explicitly.
        base = @properties.reverse.find { |prop| prop[0] == name && prop[1]["prop-id"] == params["prop-id"] }
        base[1]["altid"] = params["altid"] if base
        values, structured_params = Structured.write(object, name: name == "n", phonetic: true)
        phonetic_params = params.merge(structured_params).merge("phonetic" => object.fetch("phoneticSystem", "script"))
        phonetic_params["script"] = object["phoneticScript"] if object["phoneticScript"]
        add(name, phonetic_params, "text", values)
      end

      def build_anniversaries
        @card.fetch("anniversaries", {}).each do |id, object|
          name = { "birth" => "bday", "death" => "deathdate", "wedding" => "anniversary" }[object["kind"]]
          next unless name

          params = object.fetch("vCardParams", {}).merge("prop-id" => id)
          # JSContact's date numbers are Gregorian, even with another calendarScale.
          # Preserve other calendar metadata through the JSPROP residual instead.
          params.delete("calscale") if params["calscale"] && !params["calscale"].to_s.casecmp?("gregorian")
          if object["date"]
            date = object["date"]
            if date["@type"] == "Timestamp"
              add(name, params, "date-and-or-time", date["utc"].sub(/\.\d+Z\z/, "Z"))
            elsif (value = partial_date(date))
              date_params = params.dup
              date_params["calscale"] = "gregorian" if date["calendarScale"] == "gregorian"
              add(name, date_params, "date", value)
            end
          end
          next unless object["place"] && %w[birth death].include?(object["kind"])

          place = object["place"]
          place_params = { "prop-id" => id }.merge(place.fetch("vCardParams", {}))
          if place["coordinates"]
            add("#{object["kind"]}place", place_params, "uri", place["coordinates"])
          elsif place["full"]
            add("#{object["kind"]}place", place_params, "text", place["full"])
          end
        end
      end

      def partial_date(date)
        if date["year"]
          value = format("%04d", date["year"])
          value += format("-%02d", date["month"]) if date["month"]
          value += format("-%02d", date["day"]) if date["month"] && date["day"]
        elsif date["month"] && date["day"]
          value = format("--%<month>02d-%<day>02d", month: date["month"], day: date["day"])
        end
        return unless value

        JCardJCal::ValueTypes.from_json(value, "date", format: :vcard)
      rescue JCardJCal::ValueError
        nil
      end

      def build_speak_to_as
        object = @card.fetch("speakToAs", {})
        add("gramgender", object.fetch("vCardParams", {}), "text", object["grammaticalGender"]) if object["grammaticalGender"]
        object.fetch("pronouns", {}).each do |id, pronouns|
          params = common_params(pronouns, id)
          add("pronouns", params, "text", pronouns["pronouns"])
          add_label(pronouns, params)
        end
      end

      # RFC 9555 §2.3.11 reversed: emit the translated properties under LANGUAGE/ALTID.
      def build_localizations
        @card.fetch("localizations", {}).each do |language, patch|
          localized = PatchObject.new(patch).apply(@card)
          localized.delete("localizations")
          alternative = self.class.new(localized).build_properties
          alternative.each do |property|
            next if %w[version language jsprop].include?(property[0])
            next if @properties.include?(property)

            candidate = copy(property)
            identity = property_identity(candidate)
            base = @properties.find { |item| property_identity(item) == identity && !item[1]["language"] }
            if !base && candidate[1]["phonetic"]
              base = @properties.find do |item|
                item[0] == candidate[0] && item[1]["prop-id"] == candidate[1]["prop-id"] &&
                  !item[1]["phonetic"] && !item[1]["language"]
              end
            end
            next unless base
            next if base[3..] == candidate[3..] && base[1].except("altid") == candidate[1].except("altid")

            alt_id = base[1]["altid"] ||= base[1].fetch("prop-id", candidate[0])
            candidate[1]["altid"] = alt_id
            candidate[1]["language"] = language
            @properties << candidate
          end
        end
      end

      # jCard's generic writer quotes only when necessary; JSPTR always requires quotes.
      def quote_pointers(text)
        text.gsub(/^(?:[A-Za-z0-9-]+\.)?JSPROP[^\r\n]*(?:\r\n[ \t][^\r\n]*)*\r\n/) do |folded|
          line = JCardJCal::ContentLine::Reader.new(folded).first
          content = line.group ? "#{line.group}.JSPROP" : +"JSPROP"
          line.params.each do |key, value|
            values = Array(value).map do |item|
              encoded = JCardJCal::ContentLine::ParamCodec.encode(item)
              key == "jsptr" && !encoded.start_with?('"') ? "\"#{encoded}\"" : encoded
            end
            content << ";#{key.upcase}=#{values.join(",")}"
          end
          content << ":#{line.value}"
          result = +""
          width = 0
          content.each_char do |character|
            if width + character.bytesize > 75
              result << "\r\n "
              width = 1
            end
            result << character
            width += character.bytesize
          end
          result << "\r\n"
        end
      end

      def property_identity(prop)
        [prop[0], prop[1]["prop-id"], prop[1]["phonetic"], prop[1]["group"]]
      end

      def common_params(object, id)
        params = object.fetch("vCardParams", {}).dup
        params["prop-id"] = id
        params["pref"] = object["pref"].to_s if object["pref"]
        params["mediatype"] = object["mediaType"] if object["mediaType"]
        types = Array(params.delete("type")).flat_map { |value| value.split(",") }
        object.fetch("contexts", {}).each { |context, enabled| types << CONTEXTS.key(context) if enabled && CONTEXTS.value?(context) }
        object.fetch("features", {}).each_key { |feature| types << FEATURES.key(feature) if FEATURES.value?(feature) }
        params["type"] = types.uniq unless types.empty?
        params["group"] ||= "label#{@properties.length}" if object["label"]
        params
      end

      def add_label(object, params)
        add("x-ablabel", { "group" => params["group"] }, "text", object["label"]) if object["label"]
      end

      def compact_timestamp(value)
        JCardJCal::ValueTypes.to_text(value.sub(/\.\d+Z\z/, "Z"), "timestamp", format: :vcard)
      end

      def add(name, params, type, *values)
        # Preserved source properties already carry parameters that have no scalar counterpart.
        return if name != "version" && @raw.any? { |prop| prop[0] == name && prop[2..] == [type, *values] }

        property = [name, copy(params), type, *copy(values)]
        JCard::Property.new(property, registry: REGISTRY)
        @properties << property
        true
      rescue JCardJCal::ValidationError => e
        raise if e.is_a?(JCardJCal::LimitError)

        # Valid JSON strings and extension values may have no native vCard encoding.
        false
      end

      def uri?(value)
        JCardJCal::ValueTypes.from_json(value, "uri", format: :vcard)
        true
      rescue JCardJCal::ValueError
        false
      end

      def copy(value) = Jscontact.deep_copy(value)

      def difference(before, after, path = "")
        if before.is_a?(Hash) && after.is_a?(Hash)
          null_key = after.keys.find { |key| after[key].nil? && (!before.key?(key) || !before[key].nil?) }
          if null_key
            return { path => after } unless path.empty?

            pointer = "/#{null_key.gsub("~", "~0").gsub("/", "~1")}"
            raise ConversionError.new("JSPROP cannot represent a top-level null value: null deletes a property", pointer: pointer)
          end
          (before.keys | after.keys).each_with_object({}) do |key, result|
            escaped = key.gsub("~", "~0").gsub("/", "~1")
            child_path = path.empty? ? escaped : "#{path}/#{escaped}"
            if before.key?(key) == after.key?(key)
              result.merge!(difference(before[key], after[key], child_path))
            else
              result[child_path] = after[key]
            end
          end
        elsif before != after
          { path => after }
        else
          {}
        end
      end
    end
  end
end
