# frozen_string_literal: true

module Jscontact
  module VCard
    # RFC 9555 §§2.5.5, 2.6.1 and 3.3.1; positions follow RFC 9554 §2.
    module Structured
      NAME_KINDS = %w[surname given given2 title credential surname2 generation].freeze
      ADDRESS_KINDS = %w[postOfficeBox apartment name locality region postcode country room apartment floor number name
                         building block subdistrict district landmark direction].freeze

      module_function

      def read(values, params, name:)
        values = Array(values)
        positions = components(values, name: name)
        result = {}
        if (ordered = order(params["jscomps"], positions))
          result["components"] = ordered[0]
          result["isOrdered"] = true
          result["defaultSeparator"] = ordered[1] unless ordered[1].nil?
        elsif !positions.empty?
          result["components"] = positions.values
        end
        if name && params["sort-as"]
          sort = Array(params["sort-as"])
          result["sortAs"] = NAME_KINDS.each_with_index.to_h { |kind, i| [kind, sort[i]] }.reject { |_, v| v.nil? || v.empty? }
          result.delete("sortAs") if result["sortAs"].empty?
        end
        result
      end

      def components(values, name:)
        kinds = name ? NAME_KINDS : ADDRESS_KINDS
        result = {}
        values.each_with_index do |part, index|
          next if !name && values.length > 7 && [1, 2].include?(index)

          Array(part).each_with_index do |value, subindex|
            next if value.empty?
            next if name && ((index.zero? && Array(values[5]).include?(value)) || (index == 4 && Array(values[6]).include?(value)))

            key = subindex.zero? ? index.to_s : "#{index},#{subindex}"
            result[key] = { "kind" => kinds.fetch(index), "value" => value }
          end
        end
        result
      end

      def order(value, positions)
        return unless value.is_a?(String)

        entries = JCardJCal::ContentLine::TextCodec.split(value, ";")
        first = entries.shift
        return unless first == "" || first&.start_with?("s,")

        entries = entries.map do |entry|
          next entry if entry.start_with?("s,")
          next unless /\A\d+(?:,\d+)?\z/.match?(entry)

          indices = entry.split(",").map { |index| index.sub(/\A0+(?=\d)/, "") }
          next if indices[1] == "0"

          indices.join(",")
        end
        return if entries.any?(&:nil?)

        positional = entries.reject { |entry| entry.start_with?("s,") }
        return unless positional.length == positions.length && positional.uniq.length == positional.length && positional.all? { |entry| positions.key?(entry) }

        components = entries.map do |entry|
          entry.start_with?("s,") ? { "kind" => "separator", "value" => unescape_separator(entry[2..]) } : positions.fetch(entry).dup
        end
        [components, first.empty? ? nil : unescape_separator(first[2..])]
      end

      def write(object, name:, phonetic: false)
        kinds = name ? NAME_KINDS : ADDRESS_KINDS
        parts = Array.new(kinds.length) { [] }
        entries = []
        Array(object["components"]).each do |component|
          kind = component["kind"]
          if kind == "separator"
            entries << "s,#{escape_separator(component["value"])}"
            next
          end
          index = name ? kinds.index(kind) : kinds.rindex(kind)
          next unless index

          value = phonetic ? component.fetch("phonetic", component["value"]) : component["value"]
          subindex = parts[index].length
          entries << (subindex.zero? ? index.to_s : "#{index},#{subindex}")
          parts[index] << value
        end
        if name
          parts[0].concat(parts[5])
          parts[4].concat(parts[6])
        else
          parts[1] = [parts.values_at(7, 9, 8, 12).flatten.join(" ")]
          parts[2] = [parts.values_at(10, 11, 13, 17, 16, 14, 15).flatten.join(" ")]
        end
        params = {}
        if object["isOrdered"]
          separator = object.key?("defaultSeparator") ? "s,#{escape_separator(object["defaultSeparator"])}" : ""
          params["jscomps"] = ([separator] + entries).join(";") unless entries.empty?
        end
        params["sort-as"] = kinds.map { |kind| object["sortAs"].fetch(kind, "") } if name && object["sortAs"]
        [parts.map { |part| part.length > 1 ? part : part.fetch(0, "") }, params]
      end

      def full_name(object)
        components = Array(object["components"])
        return "" if components.empty?
        return components.map { |component| component["value"] }.join(" ") unless object["isOrdered"]

        result = +""
        previous = nil
        components.each do |component|
          kind = component["kind"]
          result << object.fetch("defaultSeparator", " ") if previous && previous != "separator" && kind != "separator"
          result << component["value"]
          previous = kind
        end
        result
      end

      def escape_separator(value)
        value.gsub(/[\\,;]/) { |char| "\\#{char}" }
      end

      def unescape_separator(value)
        value.gsub(/\\([\\,;])/, '\\1')
      end
    end
  end
end
