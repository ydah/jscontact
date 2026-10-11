# frozen_string_literal: true

require "spec_helper"
require_relative "../lib/jscontact/patch_object"

RSpec.describe Jscontact::PatchObject do
  let(:card) { { "@type" => "Card", "version" => "2.0", "name" => { "full" => "Aki" } } }

  it "adds, replaces and removes object members without changing either input" do
    original = { "nested" => { "value" => "old", "remove" => 1 } }
    changes = { "nested/value" => { "new" => [1] }, "nested/remove" => nil, "absent" => nil }
    patch = described_class.new(changes)
    result = patch.apply(original)
    expect(result).to eq("nested" => { "value" => { "new" => [1] } })
    result["nested"]["value"]["new"] << 2
    expect(original).to eq("nested" => { "value" => "old", "remove" => 1 })
    expect(patch.to_h).to eq(changes)
  end

  it "decodes JSON Pointer escapes once, including empty and dash object keys" do
    original = { "a/b" => { "~1" => 1 }, "" => 2, "-" => 3 }
    expect(described_class.new({ "a~1b/~01" => 4, "" => 5, "-" => 6 }).apply(original)).to eq(
      "a/b" => { "~1" => 4 }, "" => 5, "-" => 6
    )
  end

  it "replaces existing array members and permits null inside replacement objects" do
    original = { "items" => [{ "name" => "old" }, false] }
    expect(described_class.new({ "items/0/name" => "new", "items/1" => { "x" => nil } }).apply(original)).to eq(
      "items" => [{ "name" => "new" }, { "x" => nil }]
    )
  end

  ["-", "01", "-1", "2", "999999999999999999999999999999"].each do |index|
    it "rejects array index #{index.inspect}" do
      expect { described_class.new({ "items/#{index}" => 1 }).apply({ "items" => [0, 0] }) }.to raise_error(Jscontact::ValidationError)
    end
  end

  it "does not delete an array member or traverse an absent parent" do
    expect { described_class.new({ "items/0" => nil }).apply({ "items" => [0] }) }.to raise_error(Jscontact::ValidationError)
    expect { described_class.new({ "missing/value" => 1 }).apply({}) }.to raise_error(Jscontact::ValidationError)
    expect { described_class.new({ "scalar/value" => 1 }).apply({ "scalar" => nil }) }.to raise_error(Jscontact::ValidationError)
  end

  it "rejects conflicting ancestor paths while accepting neighboring names" do
    expect { described_class.new({ "name/full" => "B", "name" => {} }).apply(card) }.to raise_error(Jscontact::ValidationError)
    expect(described_class.new({ "a" => 1, "ab" => 2 }).apply({})).to eq("a" => 1, "ab" => 2)
  end

  it "rejects malformed pointer escapes with the patch key's JSON Pointer" do
    expect { described_class.new({ "name/~2" => "B" }).apply(card) }.to raise_error(Jscontact::ValidationError) { |error|
      expect(error.pointer).to eq("/name~1~02")
    }
  end

  it "validates property types and required properties atomically for typed objects" do
    changes = { "name/full" => "B", "version" => nil }
    expect { described_class.new(changes).apply(card) }.to raise_error(Jscontact::ValidationError)
    expect(card["name"]["full"]).to eq("Aki")
    expect { described_class.new({ "name/full" => 4 }).apply(card) }.to raise_error(Jscontact::ValidationError)
    expect { described_class.new({ "@type" => "Name" }).apply(card) }.to raise_error(Jscontact::ValidationError)
    expect { described_class.new({ "@type" => nil }).apply(card) }.to raise_error(Jscontact::ValidationError)
  end

  it "checks patch limits, cycles, and invalid JSON values before applying" do
    expect { described_class.new({ "a" => 1, "b" => 2 }, max_patches: 1) }.to raise_error(Jscontact::LimitError)
    expect { described_class.new({ "a" => Float::NAN }).apply({}) }.to raise_error(Jscontact::ValidationError)
    cyclic = {}
    cyclic["self"] = cyclic
    expect { described_class.new({ "a" => cyclic }) }.to raise_error(Jscontact::ValidationError)
  end
end
