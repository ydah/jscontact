# frozen_string_literal: true

RSpec.describe "JSON round trips and resource boundaries" do
  it "round trips generated Cards without losing unknown or nested extension values" do
    random = Random.new(9553)
    alphabet = ["a", "Z", "0", " ", "\n", "\t", "\\", '"', "青", "😀"]
    100.times do |index|
      text = Array.new(random.rand(1..40)) { alphabet.sample(random: random) }.join
      card = JSContact::Card.build(version: index.even? ? "1.0" : "2.0", uid: "urn:uuid:sample-#{index}") do |contact|
        contact.name = { full: text }
        contact.add_email(address: "user#{index}@example.test", pref: random.rand(1..100))
        contact["futureProperty"] = { "a/b~c" => [nil, true, false, random.rand(-((2**53) - 1)..((2**53) - 1)), text] }
        contact["example.test:nested"] = { "null" => nil, "array" => [{ "value" => text }, random.rand] }
      end
      encoded = card.to_json
      parsed = JSContact.parse(encoded).to_h
      expect(parsed).to eq(card.to_h), "Round trip changed #{card.to_h.inspect} to #{parsed.inspect} via #{encoded}"
      expect(card.to_json).to eq(encoded)
    end
  end

  it "preserves every binary64 bit when serializing finite extension numbers" do
    bit_patterns = %w[3fa1afd066484c70 0000000000000000 8000000000000000 0000000000000001
                      0010000000000000 7fefffffffffffff ffefffffffffffff 3ff0000000000000]
    values = bit_patterns.map { |bits| [bits].pack("H*").unpack1("G") }
    values.concat(Random.new(9982).bytes(4096).unpack("G*").select(&:finite?))
    card = JSContact::Card.build
    card["example.test:numbers"] = { "values" => values, "integer" => 1 }

    restored = JSContact.parse(card.to_json)["example.test:numbers"]
    expect(restored["integer"]).to be_a(Integer)
    expect(restored["values"]).to all(be_a(Float))
    values.zip(restored["values"]).each do |original, actual|
      expect([actual].pack("G").unpack1("H*")).to eq([original].pack("G").unpack1("H*"))
    end
    expect(card["example.test:numbers"]["values"]).to eq(values)
  end

  it "enforces exact byte, depth, map and data URI boundaries" do
    data = { "@type" => "Card", "version" => "2.0", "example.test:value" => "青" }
    source = JSON.generate(data)
    expect(JSContact.parse(source, max_input_size: source.bytesize).to_h).to eq(data)
    expect { JSContact.parse(source, max_input_size: source.bytesize - 1) }.to raise_error(JSContact::LimitError)

    data["example.test:value"] = { "a" => ["leaf"] }
    expect(JSContact.parse(JSON.generate(data), max_depth: 3).to_h).to eq(data)
    expect { JSContact.parse(JSON.generate(data), max_depth: 2, strict: false) }.to raise_error(JSContact::LimitError)

    data.delete("example.test:value")
    data["emails"] = { "e1" => { "address" => "one@example.test" }, "e2" => { "address" => "two@example.test" } }
    expect(JSContact.parse(JSON.generate(data), max_map_size: 2).emails.size).to eq(2)
    expect { JSContact.parse(JSON.generate(data), max_map_size: 1, strict: false) }.to raise_error(JSContact::LimitError)

    ["data:text/plain;base64,YWJj", "data:text/plain,%61%62%63"].each do |uri|
      source = JSON.generate({ "@type" => "Card", "version" => "2.0", "example.test:uri" => uri })
      expect(JSContact.parse(source, max_data_uri_size: 3)).to be_valid
      expect { JSContact.parse(source, max_data_uri_size: 2, strict: false) }.to raise_error(JSContact::LimitError)
    end
  end

  it "checks limits and invalid values again after mutable nested edits" do
    card = JSContact::Card.build
    card["example.test:data"] = []
    card["example.test:data"] << card["example.test:data"]
    expect { card.to_json }.to raise_error(JSContact::ValidationError)
    expect { card.to_h }.to raise_error(JSContact::ValidationError)

    card = JSContact::Card.new(nil, max_map_size: 1)
    card.emails = { "e1" => { "address" => "one@example.test" } }
    expect { card.add_email(address: "two@example.test") }.to raise_error(JSContact::LimitError)
    expect(card.emails.keys).to eq(["e1"])
  end
end
