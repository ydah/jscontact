# frozen_string_literal: true

require "spec_helper"
require "jscontact/vcard"
require_relative "../script/prepare_rfc_fixtures"
require_relative "../script/compare_contacts"

RSpec.describe "downloaded RFC conformance corpus" do
  directory = RFCFixtures::DIRECTORY
  manifest_path = File.join(directory, "manifest.json")
  raise "Run bundle exec rake fixtures before the RFC examples" unless File.file?(manifest_path)

  JSON.parse(File.read(manifest_path)).each do |example|
    title = "RFC #{example.fetch("rfc")} §#{example.fetch("section")} figure #{example.fetch("figure")}"
    data = JSON.parse(File.read(File.join(directory, example.fetch("json"))))

    it "preserves every property in #{title}" do
      card = JSContact.parse(JSON.generate(data))
      expect(card.to_h).to eq(data)
      expect(JSContact.parse(card.to_json).to_h).to eq(data)
    end

    next unless example["vcard"]

    text = File.read(File.join(directory, example.fetch("vcard")))
    it "converts the vCard to #{title}" do
      converted = JSContact::VCard.to_jscontact(text)
      expect(ContactComparison.normalize(converted.to_h)).to eq(ContactComparison.normalize(data))
      text.scan(/;PROP-ID=([^;:\r\n]+)/).flatten.each do |id|
        expect(converted.to_h.fetch("phones")).to have_key(id)
      end
    end

    it "converts #{title} to vCard and back" do
      output = JSContact::VCard.from_jscontact(JSContact::Card.new(data))
      converted = JSContact::VCard.to_jscontact(output)
      expect(ContactComparison.normalize(converted.to_h)).to eq(ContactComparison.normalize(data))
    end
  end

  it "implements RFC 9982's optional UID only for version 2.0" do
    expect(JSContact.parse('{"@type":"Card","version":"2.0"}').to_h).not_to have_key("uid")
    expect { JSContact.parse('{"@type":"Card","version":"1.0"}') }.to raise_error(JSContact::ValidationError)
    card = JSContact::VCard.to_jscontact("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Release Test\r\nEND:VCARD\r\n")
    expect(card.to_h).not_to have_key("uid")
    expect(card.version).to eq("2.0")
  end
end
