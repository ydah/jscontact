# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../script/prepare_rfc_fixtures"
require_relative "../script/compare_contacts"

RSpec.describe RFCFixtures do
  around do |example|
    Dir.mktmpdir("jscontact-rfc") do |directory|
      @directory = directory
      example.run
    end
  end

  let(:path) { File.join(@directory, "source.xml") }
  let(:source) { { "url" => "https://www.rfc-editor.org/rfc/rfc9553.xml", "sha256" => Digest::SHA256.hexdigest("source") } }

  it "downloads over HTTPS once and verifies cached content on every use" do
    expect(described_class).to receive(:system).once do |*arguments|
      expect(arguments).to include("--fail", "--proto", "=https", source.fetch("url"))
      File.write(arguments.last, "source")
      true
    end
    2.times { described_class.fetch(source, path) }
    File.write(path, "changed source")
    expect { described_class.fetch(source, path) }.to raise_error(/SHA-256 mismatch/)
  end

  it "fails incomplete downloads without installing a partial cache entry" do
    allow(described_class).to receive(:system) do |*arguments|
      File.write(arguments.last, "source")
      false
    end
    expect { described_class.fetch(source, path) }.to raise_error(/Download failed/)
    expect(Dir.children(@directory)).to be_empty
  end

  it "rejects successful downloads with an unexpected checksum" do
    allow(described_class).to receive(:system) do |*arguments|
      File.write(arguments.last, "different")
      true
    end
    expect { described_class.fetch(source, path) }.to raise_error(/SHA-256 mismatch/)
    expect(Dir.children(@directory)).to be_empty
  end

  it "reproduces all examples from the pinned source XML" do
    FileUtils.cp_r(File.join(described_class::ROOT, "sources"), @directory)
    stub_const("RFCFixtures::ROOT", @directory)
    stub_const("RFCFixtures::DIRECTORY", File.join(@directory, "fixtures"))
    expect(described_class).not_to receive(:system)
    expect { described_class.prepare }.to output(/Extracted 97 examples/).to_stdout
    expect { described_class.verify_fixtures(described_class::DIRECTORY) }.not_to raise_error
    notice = File.read(File.join(described_class::DIRECTORY, "LICENSE"))
    expect(notice).to include("Revised BSD License", "IETF Trust", "https://trustee.ietf.org/license-info")
    manifest = JSON.parse(File.read(File.join(described_class::DIRECTORY, "manifest.json")))
    expect(manifest.group_by { |entry| entry.fetch("rfc") }.transform_values(&:length)).to eq(9553 => 42, 9555 => 54, 9610 => 1)
  end

  it "detects removed or modified fixture files" do
    FileUtils.cp_r(described_class::DIRECTORY, @directory)
    directory = File.join(@directory, "fixtures")
    fixture = Dir.glob(File.join(directory, "*.json")).find { |file| !file.end_with?("manifest.json") }
    File.write(fixture, "{}\n")
    expect { described_class.verify_fixtures(directory) }.to raise_error(/Fixture fingerprint mismatch/)
    File.write(File.join(directory, "manifest.json"), "[]\n")
    expect { described_class.verify_fixtures(directory) }.to raise_error(/Fixture count mismatch/)
  end
end

RSpec.describe ContactComparison do
  it "preserves arbitrary vendor JSON rather than interpreting its keys as JSContact fields" do
    opaque = { "@type" => "Custom", "version" => "a", "isOrdered" => false, "defaultSeparator" => " ",
               "components" => [{ "z" => 1 }, { "a" => 2 }], "emails" => { "opaque-id" => { "address" => "keep" } } }
    card = { "@type" => "Card", "version" => "2.0", "example.test:opaque" => opaque }
    expect(described_class.normalize(card).fetch("example.test:opaque")).to eq(opaque)
    different = card.merge("example.test:opaque" => opaque.merge("version" => "b"))
    expect(described_class.normalize(card)).not_to eq(described_class.normalize(different))
  end

  it "normalizes model Ids and references without changing vendor identifiers" do
    card = { "@type" => "Card", "version" => "2.0", "organizations" => { "original" => { "name" => "Company" } },
             "titles" => { "t" => { "kind" => "title", "name" => "Role", "organizationId" => "original" } },
             "localizations" => { "fr" => { "titles/t/name" => "Titre" } },
             "example.test:opaque" => { "organizationId" => "original" } }
    normalized = described_class.normalize(card)
    expect(normalized.dig("titles", "titles-1", "organizationId")).to eq("organizations-1")
    expect(normalized.dig("localizations", "fr")).to eq("titles/titles-1/name" => "Titre")
    expect(normalized.dig("example.test:opaque", "organizationId")).to eq("original")
  end

  it "preserves vendor patch values and their JSON Pointer escaping" do
    opaque = { "@type" => "Custom", "version" => "keep", "components" => [2, 1] }
    card = { "@type" => "Card", "version" => "2.0", "example.test:opaque" => {},
             "localizations" => { "fr" => { "example.test:opaque" => opaque } } }
    expect(described_class.normalize(card).dig("localizations", "fr", "example.test:opaque")).to eq(opaque)
  end

  it "keeps both modeled and vendor vCard metadata in conformance comparisons" do
    opaque = { "vCard" => { "properties" => [1] }, "vCardParams" => "opaque", "vCardName" => "opaque" }
    card = { "@type" => "Card", "version" => "2.0", "example.test:opaque" => opaque,
             "emails" => { "e" => { "address" => "a@example.test", "vCardParams" => { "x-name" => "v" } } } }
    normalized = described_class.normalize(card)
    expect(normalized.fetch("example.test:opaque")).to eq(opaque)
    expect(normalized.dig("emails", "emails-1")).to eq("address" => "a@example.test", "vCardParams" => { "x-name" => "v" })
  end
end
