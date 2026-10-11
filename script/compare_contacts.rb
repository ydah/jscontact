# frozen_string_literal: true

require "json"
require_relative "../lib/jscontact"

module ContactComparison
  module_function

  def canonical(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
    when Array then value.map { |item| canonical(item) }
    else value
    end
  end

  def normalize(card)
    card = JSON.parse(JSON.generate(card))
    card = normalize_value(card, "Card", {}, card)
    ids = {}
    collect_ids(card, "Card", ids)
    canonical(normalize_value(card, "Card", ids, card))
  end

  def collect_ids(value, type, ids)
    return unless value.is_a?(Hash) && JSContact::SCHEMA.key?(type)

    JSContact::SCHEMA.fetch(type).fetch("properties").each do |key, rule|
      child = value[key]
      signature = rule.fetch("type")
      if signature.start_with?("Id[") && child.is_a?(Hash)
        ordered = child.sort_by { |_, object| JSON.generate(canonical(object.except("@type", "organizationId"))) }
        ids[key] = ordered.each_with_index.to_h { |(id, _), index| [id, "#{key}-#{index + 1}"] }
      end
      collect_ids(child, signature, ids)
    end
  end

  def normalize_value(value, signature, ids, card, property = nil)
    return value unless signature

    if JSContact::SCHEMA.key?(signature) && value.is_a?(Hash)
      normalize_object(value, signature, ids, card)
    elsif signature == "PartialDate|Timestamp" && value.is_a?(Hash)
      normalize_value(value, value.fetch("@type", "PartialDate"), ids, card)
    elsif signature.end_with?("[]") && value.is_a?(Array)
      value.map { |item| normalize_value(item, signature.delete_suffix("[]"), ids, card) }
    elsif (match = /\A(?:Id|String|LanguageTag)\[(.+)\]\z/.match(signature)) && value.is_a?(Hash)
      value.to_h { |key, item| [ids.fetch(property, {}).fetch(key, key), normalize_value(item, match[1], ids, card)] }
    elsif signature == "PatchObject" && value.is_a?(Hash)
      value.to_h do |path, item|
        renamed, type = patch_path(path, ids, card)
        [renamed, normalize_value(item, type, ids, card)]
      end
    else
      value
    end
  end

  def normalize_object(value, type, ids, card)
    fields = JSContact::SCHEMA.fetch(type).fetch("properties")
    value.each_with_object({}) do |(key, child), output|
      rule = fields[key]
      next if key == "@type" && child == type && type != "Timestamp"
      next if key == "version" && type == "Card"
      next if rule&.key?("default") && child == rule["default"]

      child = ids.fetch("organizations", {}).fetch(child, child) if key == "organizationId" && type == "Title"
      child = normalize_value(child, rule&.fetch("type"), ids, card, key)
      if key == "vCardProps" && type == "Card"
        child = child.reject { |entry| entry.size == 4 && entry[0] == "version" && entry[1] == {} && entry[3] == "4.0" }
        next if child.empty?
      end
      child = child.sort_by { |entry| JSON.generate(canonical(entry)) } if key == "components" && %w[Name Address].include?(type) && value["isOrdered"] != true
      output[key] = child
    end
  end

  def patch_path(path, ids, card)
    type = "Card"
    value = card
    property = nil
    parts = path.split("/").map { |token| token.gsub(/~[01]/) { |escape| escape == "~0" ? "~" : "/" } }
    renamed = parts.map do |token|
      original = token
      if JSContact::SCHEMA.key?(type)
        type = JSContact::SCHEMA.fetch(type).fetch("properties").dig(token, "type")
        property = token
      elsif (match = /\A(?:Id|String)\[(.+)\]\z/.match(type.to_s))
        type = match[1]
        token = ids.fetch(property, {}).fetch(token, token)
      elsif type&.end_with?("[]")
        type = type.delete_suffix("[]")
      else
        type = nil
      end
      value = value.is_a?(Hash) ? value[original] : (value[original.to_i] if value.is_a?(Array))
      type = value.fetch("@type", "PartialDate") if type == "PartialDate|Timestamp" && value.is_a?(Hash)
      token.gsub("~", "~0").gsub("/", "~1")
    end
    [renamed.join("/"), type]
  end
end
