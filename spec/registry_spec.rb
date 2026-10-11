# frozen_string_literal: true

require "spec_helper"
require_relative "../script/update_registry"

RSpec.describe JSContactRegistry do
  it "matches every registered type, property, enum, version, reserved name and script code" do
    expect(described_class.audit).to be_empty
    expect { described_class.run }.to output(/match the validation metadata/).to_stdout
  end

  it "detects missing property definitions and mismatched types" do
    schema = JSContact.deep_copy(JSContact::SCHEMA)
    schema.fetch("Card").fetch("properties").delete("uid")
    schema.fetch("Title").fetch("properties").fetch("organizationId")["type"] = "Boolean"
    errors = described_class.audit(schema: schema)
    expect(errors).to include("Missing property Card.uid", "Type mismatch Title.organizationId: Boolean versus String")
  end

  it "detects missing enum values, script codes and reserved property names" do
    enums = JSContact.deep_copy(JSContact::ENUMS)
    enums.fetch("cardKind").delete("individual")
    enums.fetch("script").delete("Latn")
    schema = JSContact.deep_copy(JSContact::SCHEMA)
    schema.fetch("Card").fetch("reserved").delete("id")
    errors = described_class.audit(schema: schema, enums: enums)
    expect(errors).to include("Missing reservation Card.id", "Missing enum values for Card.kind: individual",
                              "Registered script codes differ from data/enums.yml")
  end

  it "does not install an unchecked registry update when new data needs review" do
    Dir.mktmpdir("registry-refresh") do |directory|
      stub_const("JSContactRegistry::DIRECTORY", File.join(directory, "sources"))
      manifest_path = File.join(directory, "manifest.json")
      File.write(manifest_path, JSON.generate(described_class::MANIFEST))
      stub_const("JSContactRegistry::MANIFEST_PATH", manifest_path)
      original = File.read(manifest_path)
      allow(described_class).to receive(:system) do |*arguments|
        File.write(arguments.last, "new registry data")
        true
      end
      allow(described_class).to receive(:audit).and_return(["Missing property Card.newProperty"])
      expect { described_class.run(refresh: true) }.to raise_error(/Registry metadata needs review/)
      expect(File.read(manifest_path)).to eq(original)
      expect(File).not_to exist(described_class::DIRECTORY)
      expect(File.read(File.join(directory, "review.txt"))).to eq("Missing property Card.newProperty\n")
    end
  end

  it "updates source hashes only after auditing every downloaded registry" do
    cache = described_class::DIRECTORY
    Dir.mktmpdir("registry-refresh") do |directory|
      stub_const("JSContactRegistry::DIRECTORY", File.join(directory, "sources"))
      manifest_path = File.join(directory, "manifest.json")
      File.write(manifest_path, JSON.generate(described_class::MANIFEST.merge("checked_on" => "2000-01-01")))
      stub_const("JSContactRegistry::MANIFEST_PATH", manifest_path)
      allow(described_class).to receive(:system) do |*arguments|
        name, = described_class::MANIFEST.fetch("sources").find { |_, source| arguments.include?(source.fetch("url")) }
        FileUtils.cp(File.join(cache, name), arguments.last)
        true
      end
      expect { described_class.run(refresh: true) }.to output(/source hashes updated/).to_stdout
      manifest = JSON.parse(File.read(manifest_path))
      expect(manifest.fetch("checked_on")).to eq(Date.today.iso8601)
      manifest.fetch("sources").each do |name, source|
        expect(Digest::SHA256.file(File.join(described_class::DIRECTORY, name)).hexdigest).to eq(source.fetch("sha256"))
      end
    end
  end
end
