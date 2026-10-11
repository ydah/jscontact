# frozen_string_literal: true

module Jscontact
  module Localization
    module_function

    def validate(data, **limits)
      localizations = data["localizations"]
      return [] unless localizations.is_a?(Hash)

      count = localizations.values.sum { |patch| patch.is_a?(Hash) ? patch.size : 0 }
      raise LimitError.new("Too many localization patches", pointer: "/localizations") if count > limits.fetch(:max_patches, DEFAULT_LIMITS[:max_patches])

      source = data.except("localizations")
      localizations.flat_map do |language, patch|
        prefix = Jscontact.pointer("/localizations", language)
        next [] unless patch.is_a?(Hash)

        forbidden = patch.keys.select { |path| path.is_a?(String) && (path == "localizations" || path.start_with?("localizations/")) }
        unless forbidden.empty?
          next forbidden.map { |path| Violation.new(pointer: Jscontact.pointer(prefix, path), message: "A localization cannot target localizations") }
        end

        begin
          localized = PatchObject.new(patch, **limits).apply(source, validate: false)
          Validator.new(**limits, validate_localizations: false).validate(localized).map do |error|
            owner = patch.keys.find { |key| error.pointer == "/#{key}" || error.pointer.start_with?("/#{key}/") }
            pointer = owner ? Jscontact.pointer(prefix, owner) + error.pointer.delete_prefix("/#{owner}") : prefix
            Violation.new(pointer: pointer, message: "#{error.pointer}: #{error.message}")
          end
        rescue ValidationError => e
          e.errors.map { |error| Violation.new(pointer: prefix + error.pointer.to_s, message: error.message) }
        end
      end
    end
  end

  class Card
    def localized(language)
      raise ValidationError.new("Invalid language tag", pointer: "/language") unless language.is_a?(String) && Types.language_tag?(language)

      validate!
      source = to_h
      localizations = source.fetch("localizations", {})
      key = localizations.keys.find { |tag| tag.casecmp?(language) }
      return self.class.new(source, **limits) unless key

      patch = localizations.fetch(key)
      source.delete("localizations")
      result = PatchObject.new(patch, **limits).apply(source)
      result["language"] = language
      self.class.new(result, **limits).validate!
    end
  end
end
