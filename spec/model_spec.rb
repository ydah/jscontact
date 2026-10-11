# frozen_string_literal: true

RSpec.describe "JSContact models" do
  it "builds a version 2 card with typed nested access and stable map identifiers" do
    card = JSContact::Card.build do |value|
      value.name = { full: "Aiko Example" }
      value.add_email(address: "aiko@example.test", contexts: { work: true })
      value.add_email(address: "other@example.test")
    end
    expect(card.version).to eq("2.0")
    expect(card.name).to be_a(JSContact::Name)
    expect(card.name.full).to eq("Aiko Example")
    expect(card.emails.keys).to eq(%w[e1 e2])
    expect(card.emails["e1"]).to be_a(JSContact::EmailAddress)
    card.emails["e1"].label = "Desk"
    expect(card.to_h.dig("emails", "e1", "label")).to eq("Desk")
    expect(JSContact.parse(card.to_json).to_h).to eq(card.to_h)
  end

  it "copies constructor data and exported data but permits nested model mutation" do
    source = { "@type" => "Card", "version" => "2.0", "name" => { "full" => "Before" } }
    card = JSContact::Card.new(source)
    source["name"]["full"] = "external"
    copy = card.to_h
    copy["name"]["full"] = "copy"
    card.name.full = "After"
    expect(card.name.full).to eq("After")
    expect(card.kind).to eq("individual")
    expect(card.to_h).not_to have_key("kind")
  end

  it "preserves unknown properties and nested vendor JSON without interpreting it" do
    source = { "@type" => "Card", "version" => "2.0", "futureValue" => [1, nil],
               "example.test:opaque" => { "bad/name" => { "@type" => "Card" } } }
    expect(JSContact.parse(JSON.generate(source)).to_h).to eq(source)
  end

  it "retains version 1 until explicitly upgraded, without renumbering map keys" do
    source = { "@type" => "Card", "version" => "1.0", "uid" => "legacy",
               "phones" => { "old-key" => { "number" => "123" } } }
    card = JSContact.parse(JSON.generate(source))
    expect(JSON.parse(card.to_json)).to eq(source)
    upgraded = JSContact.upgrade(card)
    expect(upgraded.version).to eq("2.0")
    expect(upgraded.phones.keys).to eq(["old-key"])
    expect(card.version).to eq("1.0")
  end

  it "can emit explicit nested types, including polymorphic anniversary dates" do
    card = JSContact::Card.build(explicit_types: true) do |value|
      value.name = { full: "Test" }
      value.anniversaries = { day: { kind: "birth", date: { year: 2004 } } }
    end
    expect(card.to_h.dig("name", "@type")).to eq("Name")
    expect(card.to_h.dig("anniversaries", "day", "date", "@type")).to eq("PartialDate")
  end

  it "provides enumerable typed maps with validated identifiers and collision-free insertion" do
    card = JSContact::Card.build
    card.emails = { "e1" => { address: "first@example.test" }, "e3" => { address: "third@example.test" } }
    expect(card.add_email(address: "second@example.test")).to eq("e2")
    expect(card.emails.map { |id, email| [id, email.address] }.size).to eq(3)
    expect { card.emails["bad/id"] = { address: "x@example.test" } }.to raise_error(JSContact::ValidationError)
    expect(card.emails.delete("e2").address).to eq("second@example.test")
  end

  it "keeps malformed lenient input inspectable but rejects serialization" do
    card = JSContact.parse('{"@type":"Card","version":"2.0","kind":"INDIVIDUAL"}', strict: false)
    expect(card).not_to be_valid
    expect(card.errors.map(&:pointer)).to include("/kind")
    expect { card.to_json }.to raise_error(JSContact::ValidationError)
  end

  it "sets the mandatory type when a nested object is serialized on its own" do
    name = JSContact::Name.new({ full: "Standalone" })
    expect(JSON.parse(name.to_json)).to eq("@type" => "Name", "full" => "Standalone")
    expect(name.to_h).to eq("full" => "Standalone")
  end

  it "rejects invalid constructor limits and reports paths for unsupported Ruby values" do
    expect { JSContact.parse("{}", max_input_size: -1) }.to raise_error(ArgumentError)
    expect { JSContact::Card.new({ "name" => { "full" => Object.new } }) }.to raise_error(JSContact::ValidationError) { |error| expect(error.pointer).to eq("/name/full") }
  end

  it "supports generated typed accessors in another Ractor" do
    skip "Ractor requires CRuby" unless RUBY_ENGINE == "ruby" && defined?(Ractor)

    actor = Ractor.new do
      card = JSContact::Card.build { |value| value.name = { full: "Shared schema" } }
      card.name.full
    end
    expect(actor.respond_to?(:value) ? actor.value : actor.take).to eq("Shared schema")
    expect(Ractor.shareable?(JSContact::SCHEMA)).to be(true)
    expect(Ractor.shareable?(JSContact::ENUMS)).to be(true)
  end

  it "uses the configured depth when serializing valid deeply nested vendor data" do
    nested = 110.times.reduce("leaf") { |value, _| [value] }
    source = JSON.generate({ "@type" => "Card", "version" => "2.0", "example.test:nested" => nested }, max_nesting: 128)
    card = JSContact.parse(source, max_depth: 128)
    expect(JSContact.parse(card.to_json, max_depth: 128).to_h).to eq(card.to_h)
  end
end
