# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Card localizations" do
  let(:data) do
    { "@type" => "Card", "version" => "2.0", "name" => { "full" => "Aki" },
      "localizations" => { "ja" => { "name/full" => "アキ" } } }
  end

  it "returns a validated independent Card with the selected patch and language" do
    card = JSContact::Card.new(data)
    localized = card.localized("ja")
    expect(localized.name.full).to eq("アキ")
    expect(localized.language).to eq("ja")
    expect(localized.to_h).not_to have_key("localizations")
    expect(card.to_h).to eq(data)
    localized.name.full = "別名"
    expect(card.name.full).to eq("Aki")
  end

  it "returns a copy without claiming a translation when no patch matches" do
    card = JSContact::Card.new(data)
    expect(card.localized("fr").to_h).to eq(data)
    expect(card.localized("fr")).not_to equal(card)
  end

  it "matches language tags without case sensitivity" do
    expect(JSContact::Card.new(data).localized("JA").name.full).to eq("アキ")
  end

  it "rejects patches that target localizations itself or its descendants" do
    %w[localizations localizations/en].each do |path|
      data["localizations"]["ja"] = { path => {} }
      card = JSContact::Card.new(data)
      expect(card.errors.map(&:pointer)).to include("/localizations/ja/#{path.gsub("/", "~1")}")
      expect { card.localized("ja") }.to raise_error(JSContact::ValidationError)
    end
  end

  it "reports a bad localized value at its patch entry" do
    data["localizations"]["ja"] = { "name/full" => 123 }
    card = JSContact::Card.new(data)
    expect(card.errors.map(&:pointer)).to include("/localizations/ja/name~1full")
    expect { card.to_json }.to raise_error(JSContact::ValidationError)
  end

  it "rejects deletion of mandatory properties, incomplete paths and array insertion" do
    [{ "version" => nil }, { "missing/value" => "x" }, { "name/components/-" => { "kind" => "given", "value" => "A" } }].each do |patch|
      data["localizations"]["ja"] = patch
      expect { JSContact.parse(JSON.generate(data)) }.to raise_error(JSContact::ValidationError)
    end
  end

  it "limits all locale patches together even in lenient mode" do
    data["localizations"]["en"] = { "name/full" => "English name" }
    expect { JSContact.parse(JSON.generate(data), strict: false, max_patches: 1) }.to raise_error(JSContact::LimitError)
  end

  it "rejects an invalid requested language tag" do
    expect { JSContact::Card.new(data).localized("not_a_tag") }.to raise_error(JSContact::ValidationError)
  end
end
