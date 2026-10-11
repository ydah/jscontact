# frozen_string_literal: true

require "json"
require "fileutils"
require "rexml/document"
require "rexml/xpath"

module RFCExamples
  NUMBERS = [9553, 9555, 9610, 9982].freeze
  UID = "urn:uuid:00000000-0000-4000-8000-000000000001"

  module_function

  def ancestor(element, name)
    element = element.parent until element.nil? || element.name == name
    element
  end

  def json_example(original, number, figure, notes)
    text = original.strip
    if text.lines.any? { |line| line.strip == "..." }
      notes << "Remove presentation ellipses."
      text = text.lines.reject { |line| line.strip == "..." }.join
    end
    if number == 9553 && figure == 35
      notes << "Join the presentation-wrapped data URI without whitespace."
      text = text.gsub(%r{\n\s+(?=[A-Za-z0-9+/=]+(?:\n|"))}, "")
    end
    if number == 9553 && figure == 36
      notes << "Close the directories object (reported erratum 8266)."
      text += "\n}"
    end
    if number == 9555 && figure == 47
      notes << "Remove the trailing JSON comma."
      text = text.sub(/,\s*}/, "\n}")
    end
    if number == 9555 && figure == 9
      notes << "Rename the second year key to day in the death PartialDate."
      count = 0
      text = text.gsub(/"year"(?=\s*:)/) do
        count += 1
        count == 2 ? '"day"' : '"year"'
      end
    end
    notes << "Wrap the property fragment in an object." unless text.start_with?("{", "[")
    data = JSON.parse(text.start_with?("{", "[") ? text : "{#{text}}")
    if number == 9553 && figure == 18
      notes << "Place the full property inside Name (reported erratum 8265)."
      data = { "name" => data }
    end
    if number == 9555 && figure == 50
      notes << "Replace the forbidden solidus in the vendor property name with a hyphen."
      phone = data.fetch("phones").values.first
      key = phone.keys.find { |name| name.include?("/") }
      phone[key.tr("/", "-")] = phone.delete(key)
    end
    data
  end

  def card(data, notes)
    missing = %w[@type version uid].reject { |key| data.key?(key) }
    notes << "Supply omitted Card envelope fields: #{missing.join(", ")}." unless missing.empty?
    { "@type" => "Card", "version" => "1.0", "uid" => UID }.merge(data)
  end

  def vcard_example(original, figure, data, notes)
    text = original.strip
    if text.match?(/\n[ \t]/)
      notes << "Unfold presentation continuations and their indentation."
      text = text.gsub(/\n[ \t]+/, "")
    end
    if figure == 5
      notes << "Correct the LANGUAGE property delimiter from '=' to ':'."
      text = text.sub(/\ALANGUAGE=/, "LANGUAGE:")
    end
    if figure == 50
      notes << "Match the corrected vendor property name and identify the referenced phone."
      text = text.sub("~1", "-").sub(/^TEL:/, "TEL;PROP-ID=phone1:")
    end
    if figure == 51
      notes << "Remove the eighth empty N component; RFC 9554 defines seven."
      text = text.sub(/^(N[^\n]+);$/, '\1')
    end
    if figure == 53
      notes << "Use ADR number index 10 and name index 11 (reported erratum 8786)."
      text = text.sub(";11;s, ;10;", ";10;s, ;11;")
      head, value = text.split(":\n", 2)
      # Unfolding above has already joined the property value onto its header.
      head, value = text.split(/:(?=;)/, 2) unless value
      fields = value.split(";", -1)
      fields[10], fields[11] = fields[11], fields[10]
      text = "#{head}:#{fields.join(";")}"
    end
    notes << "Wrap the vCard fragment with VERSION:4.0 and an omitted UID."
    uid = text.match?(/^UID[;:]/i) ? "" : "UID:#{data.fetch("uid", UID)}\n"
    "BEGIN:VCARD\nVERSION:4.0\n#{uid}#{text}\nEND:VCARD\n".gsub("\n", "\r\n")
  end

  def preserve_groups(data, text, figure, notes)
    return unless [27, 40].include?(figure)

    notes << "Include optional group preservation omitted from the JSON figure (RFC 9555 section 2.3.9)."
    group = text.match(/^([A-Za-z0-9-]+)\.(?:ORG|ROLE|TEL)[;:]/)[1]
    objects = if figure == 27
                data.fetch("organizations").values + data.fetch("titles").values.select { |title| title["kind"] == "role" }
              else
                data.fetch("phones").values
              end
    objects.each { |object| object["vCardParams"] = { "group" => group } }
  end

  def write_entry(directory, entries, number, section, figure, data, originals, vcard: nil, notes: [])
    basename = "rfc#{number}_#{section}_figure#{figure}"
    json_path = "#{basename}.json"
    File.write(File.join(directory, json_path), "#{JSON.pretty_generate(data)}\n")
    originals.each_with_index do |original, index|
      File.write(File.join(directory, "#{basename}.original#{index + 1}.txt"), original)
    end
    entry = { "rfc" => number, "section" => section, "figure" => figure, "json" => json_path, "notes" => notes }
    if vcard
      entry["vcard"] = "#{basename}.vcf"
      File.binwrite(File.join(directory, entry.fetch("vcard")), vcard)
    end
    entries << entry
  end

  def extract(source_directory, directory)
    FileUtils.mkdir_p(directory)
    entries = []
    NUMBERS.each do |number|
      document = REXML::Document.new(File.read(File.join(source_directory, "rfc#{number}.xml")))
      figures = REXML::XPath.match(document, "//figure[sourcecode]")
      figures.each do |element|
        figure = element.attributes["pn"].delete_prefix("figure-").to_i
        section = ancestor(element, "section").attributes["pn"].delete_prefix("section-")
        blocks = element.get_elements("sourcecode").reject { |block| block.attributes["type"] == "abnf" }
        next if blocks.empty?

        originals = blocks.map { |block| block.texts.map(&:value).join }
        json_index = blocks.index { |block| block.attributes["type"] != "text/plain" }
        next unless json_index

        notes = []
        data = json_example(originals[json_index], number, figure, notes)
        if number == 9610
          response = data.find { |method| method.first == "ContactCard/get" && method[1].key?("list") }
          next unless response

          data = response[1].fetch("list").first
          notes << "Select the ContactCard/get response Card and omit JMAP-only id/addressBookIds."
          data = data.except("id", "addressBookIds")
        end
        data = card(data, notes)
        vcard_index = blocks.index { |block| block.attributes["type"] == "text/plain" }
        vcard = vcard_example(originals[vcard_index], figure, data, notes) if vcard_index
        preserve_groups(data, vcard, figure, notes) if number == 9555
        write_entry(directory, entries, number, section, figure, data, originals, vcard: vcard, notes: notes)
      end
      next unless number == 9555

      example = REXML::XPath.match(document, "//sourcecode[@type='text/plain']").find { |node| !ancestor(node, "figure") }
      original = example.texts.map(&:value).join
      notes = ["Decode the standalone JSPROP JSON value and pointer into a Card fragment."]
      pointer, value = original.strip.match(/JSPTR="([^"]+)":(.+)/).captures
      data = card({ pointer => JSON.parse(value) }, notes)
      vcard = vcard_example(original, 0, data, notes)
      write_entry(directory, entries, number, "3.3.2", 0, data, [original], vcard: vcard, notes: notes)
    end
    File.write(File.join(directory, "manifest.json"), "#{JSON.pretty_generate(entries)}\n")
    puts "Extracted #{entries.length} examples"
    entries
  end
end

RFCExamples.extract(*ARGV) if $PROGRAM_NAME == __FILE__
