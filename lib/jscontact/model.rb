# frozen_string_literal: true

module Jscontact
  # A typed view over a JSON object; nested views write into their owning model.
  class Model
    attr_reader :limits

    def initialize(data = nil, strict: false, explicit_types: false, **limits)
      @limits = DEFAULT_LIMITS.merge(limits).freeze
      validator = Validator.new(**limits)
      data = { "@type" => "Card", "version" => "2.0" } if data.nil? && instance_of?(Card)
      data ||= {}
      raise ValidationError, "expected a JSON object" unless data.is_a?(Hash)

      @data = Jscontact.deep_copy(data, max_depth: @limits[:max_depth])
      @explicit_types = explicit_types
      violations = validator.validate(@data, type: type_name, root: instance_of?(Card))
      raise ValidationError, violations if strict && !violations.empty?
    end

    def self.wrap(data, limits, explicit_types)
      value = allocate
      value.instance_variable_set(:@data, data)
      value.instance_variable_set(:@limits, limits)
      value.instance_variable_set(:@explicit_types, explicit_types)
      value
    end

    def [](name)
      name = name.to_s
      rule = SCHEMA.fetch(type_name).fetch("properties")[name]
      return @data[name] unless rule
      return Jscontact.deep_copy(rule["default"]) if !@data.key?(name) && rule.key?("default")

      wrap_value(@data[name], rule.fetch("type"))
    end

    def []=(name, value)
      @data[name.to_s] = Jscontact.deep_copy(value, max_depth: @limits[:max_depth])
    end

    def key?(name)
      @data.key?(name.to_s)
    end

    def delete(name)
      @data.delete(name.to_s)
    end

    def to_h
      output = Jscontact.deep_copy(@data, max_depth: @limits[:max_depth])
      add_types(output, type_name) if @explicit_types
      output
    end

    def to_json(options = nil)
      validate!
      data = to_h
      data["@type"] ||= type_name
      Jscontact.generate_json(data, options || { max_nesting: @limits[:max_depth] })
    end

    def errors
      Validator.new(**@limits).validate(@data, type: type_name, root: instance_of?(Card))
    end
    alias warnings errors

    def valid?
      errors.empty?
    end

    def validate!
      violations = errors
      raise ValidationError, violations unless violations.empty?

      self
    end

    def ==(other)
      other.is_a?(Model) && to_h == other.to_h
    end

    protected

    def type_name
      self.class.name.split("::").last
    end

    private

    def wrap_value(value, signature)
      return value unless value.is_a?(Hash) || value.is_a?(Array)

      if SCHEMA.key?(signature) && value.is_a?(Hash)
        Jscontact.const_get(signature).wrap(value, @limits, @explicit_types)
      elsif (match = /\A(?:Id|String)\[(\w+)\]\z/.match(signature)) && SCHEMA.key?(match[1]) && value.is_a?(Hash)
        IdMap.new(value, type: match[1], limits: @limits, explicit_types: @explicit_types,
                         validate_ids: signature.start_with?("Id["))
      elsif signature.end_with?("[]") && value.is_a?(Array)
        value.map { |item| wrap_value(item, signature.delete_suffix("[]")) }
      elsif signature.include?("|") && value.is_a?(Hash)
        type = value.fetch("@type", signature.split("|").first)
        SCHEMA.key?(type) ? Jscontact.const_get(type).wrap(value, @limits, @explicit_types) : value
      else
        value
      end
    end

    def add_types(value, type)
      return unless value.is_a?(Hash)

      value["@type"] ||= type
      SCHEMA.fetch(type).fetch("properties").each do |name, definition|
        next unless value.key?(name)

        item = value[name]
        signature = definition.fetch("type")
        if SCHEMA.key?(signature)
          add_types(item, signature)
        elsif (match = /\A(?:Id|String)\[(\w+)\]\z/.match(signature)) && SCHEMA.key?(match[1]) && item.is_a?(Hash)
          item.each_value { |entry| add_types(entry, match[1]) }
        elsif signature.end_with?("[]") && SCHEMA.key?(signature.delete_suffix("[]")) && item.is_a?(Array)
          item.each { |entry| add_types(entry, signature.delete_suffix("[]")) }
        elsif signature.include?("|") && item.is_a?(Hash)
          nested_type = item.fetch("@type", signature.split("|").first)
          add_types(item, nested_type) if SCHEMA.key?(nested_type)
        end
      end
    end
  end

  # A map preserving source identifiers and exposing typed member values.
  class IdMap
    include Enumerable

    def initialize(data = {}, type:, limits: DEFAULT_LIMITS, explicit_types: false, validate_ids: true)
      @data = data
      @type = type
      @limits = limits
      @explicit_types = explicit_types
      @validate_ids = validate_ids
    end

    def [](id)
      value = @data[id.to_s]
      value.is_a?(Hash) ? Jscontact.const_get(@type).wrap(value, @limits, @explicit_types) : value
    end

    def []=(id, value)
      id = id.to_s
      raise ValidationError.new("invalid map Id", pointer: Jscontact.pointer("", id)) if @validate_ids && !Types.id?(id)
      raise LimitError, "map exceeds max_map_size" if !@data.key?(id) && @data.size >= @limits[:max_map_size]

      @data[id] = Jscontact.deep_copy(value, max_depth: @limits[:max_depth])
    end

    def each
      return enum_for(:each) unless block_given?

      @data.each_key { |id| yield id, self[id] }
      self
    end

    def keys
      @data.keys
    end

    def values
      map { |_id, value| value }
    end

    def size
      @data.size
    end
    alias length size

    def empty?
      @data.empty?
    end

    def key?(id)
      @data.key?(id.to_s)
    end

    def delete(id)
      value = self[id]
      @data.delete(id.to_s)
      value
    end

    def add(value, prefix: "id")
      counter = 1
      counter += 1 while @data.key?("#{prefix}#{counter}")
      id = "#{prefix}#{counter}"
      self[id] = value
      id
    end

    def to_h
      Jscontact.deep_copy(@data, max_depth: @limits[:max_depth])
    end
  end

  SCHEMA.each do |name, definition|
    model = const_set(name, Class.new(Model))
    definition.fetch("properties").each_key do |property|
      next if property == "@type"

      model.class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        # def full; self["full"]; end
        def #{property}; self[#{property.inspect}]; end
        # def full=(value); self["full"] = value; end
        def #{property}=(value); self[#{property.inspect}] = value; end
      RUBY
      snake = property.gsub(/([A-Z])/, '_\\1').downcase
      next if snake == property

      model.alias_method(snake, property)
      model.alias_method("#{snake}=", "#{property}=")
    end
  end

  class Card
    def self.build(version: "2.0", explicit_types: false, **properties)
      card = new({ "@type" => "Card", "version" => version }.merge(properties), explicit_types: explicit_types)
      yield card if block_given?
      card.validate!
    end

    # Returns the stable Id allocated for the new email address.
    def add_email(**properties)
      self.emails = {} unless key?("emails")
      emails.add(properties, prefix: "e")
    end
  end
end
