# frozen_string_literal: true

RSpec.describe "JSContact validation" do
  def violations(properties)
    JSContact::Card.new({ "@type" => "Card", "version" => "2.0" }.merge(properties)).errors
  end

  def pointers(properties)
    violations(properties).map(&:pointer)
  end

  it "requires the root type and version without silently repairing parsed data" do
    expect { JSContact.parse("{}") }.to raise_error(JSContact::ValidationError)
    expect(pointers("version" => "1.0")).to include("/uid")
    expect(violations({})).to be_empty
    expect(pointers("version" => "9.0")).to include("/version")
  end

  it "rejects case variants, reserved names and malformed extension names" do
    %w[Name EXTRA extra bad_name example.test:bad/name -example.test:value :foo].each do |name|
      expect(pointers(name => "x")).to include("/#{name.gsub("~", "~0").gsub("/", "~1")}")
    end
    expect(violations("例.test:custom value" => { "/" => 1 })).to be_empty
  end

  it "checks required fields and exact types in nested objects" do
    expect(pointers("emails" => { "e1" => { "pref" => 0 } })).to include("/emails/e1/address", "/emails/e1/pref")
    expect(pointers("phones" => { "p1" => { "number" => 123 } })).to include("/phones/p1/number")
    expect(pointers("name" => { "@type" => "name", "full" => "N" })).to include("/name/@type")
    expect(pointers("media" => { "m" => { "uri" => "/relative" } })).to include("/media/m/kind", "/media/m/uri")
    expect(pointers("emails" => { "bad/id" => { "address" => "ok@example.test" } })).to include("/emails/bad~1id")
  end

  it "enforces safe integer, preference, true-set and resource constraints" do
    expect(pointers("directories" => { "d" => { "kind" => "entry", "uri" => "https://example.test", "listAs" => 2**53 } })).to include("/directories/d/listAs")
    expect(pointers("keywords" => { "tag" => false })).to include("/keywords/tag")
    expect(pointers("members" => { "a" => true })).to include("/members")
    expect(violations("kind" => "group", "members" => { "a" => true })).to be_empty
    expect(pointers("prodId" => "")).to include("/prodId")
  end

  it "validates all name and address component dependencies" do
    expect(pointers("name" => {})).to include("/name")
    expect(pointers("name" => { "components" => [] })).to include("/name/components")
    expect(pointers("name" => { "full" => "N", "defaultSeparator" => " " })).to include("/name/defaultSeparator")
    name = { "components" => [{ "kind" => "given", "value" => "N", "phonetic" => "n" }], "sortAs" => { "surname" => "N" } }
    expect(pointers("name" => name)).to include("/name/components/0/phonetic", "/name/sortAs/surname")
    name["phoneticScript"] = "Latn"
    name["sortAs"] = { "given" => "N" }
    expect(violations("name" => name)).to be_empty
    name["components"] += [{ "kind" => "separator", "value" => " " }, { "kind" => "separator", "value" => "-" }]
    expect(pointers("name" => name)).to include("/name/components/1", "/name/components/2")
    expect(pointers("addresses" => { "a" => {} })).to include("/addresses/a")
  end

  it "validates required alternatives for composite objects" do
    expect(pointers("organizations" => { "o" => { "units" => [] } })).to include("/organizations/o/units")
    expect(pointers("speakToAs" => {})).to include("/speakToAs")
    expect(pointers("onlineServices" => { "o" => { "service" => "site" } })).to include("/onlineServices/o")
    expect(pointers("notes" => { "n" => { "note" => "x", "author" => {} } })).to include("/notes/n/author")
  end

  it "validates UTC dates, fractional seconds and partial Gregorian dates" do
    %w[2024-02-30T00:00:00Z 2024-01-01t00:00:00Z 2024-01-01T00:00:00+00:00 2024-01-01T00:00:00.10Z 2024-01-01T00:00:00.000Z].each do |date|
      expect(pointers("created" => date)).to include("/created")
    end
    expect(violations("created" => "2024-02-29T23:59:59.001Z")).to be_empty
    invalid_dates = [{ "month" => 1 }, { "day" => 2 }, { "year" => 2023, "month" => 2, "day" => 29 }, { "month" => 2, "day" => 30 }]
    invalid_dates.each do |date|
      expect(violations("anniversaries" => { "a" => { "kind" => "birth", "date" => date } })).not_to be_empty
    end
    expect(violations("anniversaries" => { "a" => { "kind" => "birth", "date" => { "month" => 2, "day" => 29 } } })).to be_empty
    expect(pointers("anniversaries" => { "a" => { "kind" => "birth", "date" => { "@type" => "Timestamp" } } })).to include("/anniversaries/a/date/utc")
  end

  it "rejects duplicate JSON keys, non-I-JSON numbers and invalid Unicode" do
    expect { JSContact.parse('{"@type":"Card","version":"1.0","version":"2.0"}') }.to raise_error(JSContact::ParseError)
    expect { JSContact.parse('{"@type":"Card","version":"2.0","x":9007199254740992}') }.to raise_error(JSContact::ValidationError)
    expect(pointers("example.test:n" => Float::INFINITY)).to include("/example.test:n")
    expect(pointers("name" => { "full" => "\uFFFF" })).to include("/name/full")
  end

  it "keeps configured resource limits hard even for lenient parsing" do
    expect { JSContact.parse("{}", max_depth: 0, strict: false) }.to raise_error(ArgumentError)
    json = JSON.generate({ "@type" => "Card", "version" => "2.0", "emails" => { "a" => { "address" => "a@example.test" } } })
    expect { JSContact.parse(json, strict: false, max_input_size: 10) }.to raise_error(JSContact::LimitError)
    expect { JSContact.parse(json, strict: false, max_map_size: 0) }.to raise_error(JSContact::LimitError)
    media = JSON.generate({ "@type" => "Card", "version" => "2.0", "media" => { "m" => { "kind" => "photo", "uri" => "data:image/png;base64,AAAA" } } })
    expect { JSContact.parse(media, strict: false, max_data_uri_size: 2) }.to raise_error(JSContact::LimitError)
  end

  it "handles Unicode text without splitting multibyte characters during URI checks" do
    expect(violations("name" => { "full" => "青空 テスト" })).to be_empty
    expect(violations("name" => { "full" => "𠮷田" })).to be_empty
  end

  it "accepts RFC 5322 address syntax without accepting mailbox display names" do
    ["a+b@example.test", '"quoted name"@[127.0.0.1]', "(desk) a (nested (comment)) @ example.test", "a\r\n \t@example.test"].each do |address|
      expect(violations("emails" => { "e" => { "address" => address } })).to be_empty
    end
    ["No <a@example.test>", "a b@example.test", "a..b@example.test", "a@(unclosed", "a\n@example.test"].each do |address|
      expect(pointers("emails" => { "e" => { "address" => address } })).to include("/emails/e/address")
    end
  end

  it "validates registered time zones and country codes without resolving remote URIs" do
    expect(violations("addresses" => { "a" => { "timeZone" => "Asia/Tokyo", "countryCode" => "jp", "coordinates" => "geo:35.5,139.5" } })).to be_empty
    expect(pointers("addresses" => { "a" => { "timeZone" => "Invented/Zone", "countryCode" => "ZZ",
                                              "coordinates" => "geo:91,0" } })).to include("/addresses/a/timeZone", "/addresses/a/countryCode",
                                                                                           "/addresses/a/coordinates")
  end

  it "checks language tags including private use, extension uniqueness and grandfathered tags" do
    %w[en en-US zh-Hant-TW x-private en-a-abc-x-private i-klingon].each do |tag|
      expect(violations("language" => tag)).to be_empty
    end
    %w[en- en-a en-a-abc-a-def en-abcde-abcde].each do |tag|
      expect(pointers("language" => tag)).to include("/language")
    end
  end

  it "does not let malformed base64 padding bypass the data URI size limit" do
    data = { "@type" => "Card", "version" => "2.0", "example.test:data" => "data:;base64,#{"=" * 100}" }
    expect { JSContact.parse(JSON.generate(data), strict: false, max_data_uri_size: 10) }.to raise_error(JSContact::LimitError)
  end

  it "measures percent-encoded data URIs by their decoded byte length" do
    data = { "@type" => "Card", "version" => "2.0", "example.test:data" => "data:;base64,%41%41%41%41" }
    expect(JSContact.parse(JSON.generate(data), max_data_uri_size: 3)).to be_valid
    expect { JSContact.parse(JSON.generate(data), max_data_uri_size: 2) }.to raise_error(JSContact::LimitError)
  end

  it "reports invalid Ruby string encodings as validation failures" do
    expect { JSContact::Card.new({ "name".encode("UTF-16LE") => "N" }) }.to raise_error(JSContact::ValidationError)
    expect(pointers("name" => { "full" => "N".encode("UTF-16LE") })).to include("/name/full")
  end

  it "validates jCard property values against their declared primitive type" do
    { "text" => 123, "unknown" => false, "uri" => 1, "integer" => 1.5, "float" => "1.2", "boolean" => 1,
      "date" => 2024, "time" => [], "language-tag" => false }.each do |type, value|
      expect(pointers("vCardProps" => [["x-custom", {}, type, value]])).to include("/vCardProps/0/3")
    end
    expect(violations("vCardProps" => [["x-structured", {}, "text", ["One", %w[Two Three]]],
                                       ["x-count", {}, "integer", 2], ["x-switch", {}, "boolean", true]])).to be_empty
  end

  it "enforces geographic URI parameter ordering, uniqueness and unsigned uncertainty" do
    %w[geo:1,2;u=-5 geo:1,2;crs=wgs84;crs=wgs84 geo:1,2;u=1;crs=wgs84 geo:1,2;x=ok;u=1 geo:+1,2 geo:001,2 geo:1,2;].each do |uri|
      expect(pointers("addresses" => { "a" => { "coordinates" => uri } })).to include("/addresses/a/coordinates")
    end
    %w[geo:1,2;crs=WGS84;u=0;x=hello%20world geo:1234,5678;crs=custom].each do |uri|
      expect(violations("addresses" => { "a" => { "coordinates" => uri } })).to be_empty
    end
  end

  it "accepts registered and private-use script subtags" do
    %w[Latn latn Hani Qaaa Qabx].each do |script|
      expect(violations("name" => { "full" => "Name", "phoneticScript" => script })).to be_empty
    end
    %w[XXXX Qaby Abc].each do |script|
      expect(pointers("name" => { "full" => "Name", "phoneticScript" => script })).to include("/name/phoneticScript")
    end
  end

  it "rejects the RFC 9610 reserved fields in their registered contexts" do
    expect(pointers("id" => "server", "addressBookIds" => {})).to include("/id", "/addressBookIds")
    expect(pointers("media" => { "m" => { "kind" => "photo", "uri" => "https://example.test/image", "blobId" => "server" } })).to include("/media/m/blobId")
  end

  it "validates extended jCard dates and times, including truncated values" do
    { "date" => "2023-02-29", "time" => "25:00", "date-time" => "2024-01T12:00", "timestamp" => "2024-01-01T12",
      "utc-offset" => "+25:00", "date-and-or-time" => "T--99" }.each do |type, value|
      expect(pointers("vCardProps" => [["x-custom", {}, type, value]])).to include("/vCardProps/0/3")
    end
    { "date" => "--02-29", "time" => "-30:20", "date-time" => "---02T12:00", "timestamp" => "2024-01-01T12:00:00Z",
      "utc-offset" => "+05:30", "date-and-or-time" => "T--30" }.each do |type, value|
      expect(violations("vCardProps" => [["x-custom", {}, type, value]])).to be_empty
    end
  end

  it "reports malformed Unicode inside preserved jCard values without parser exceptions" do
    %w[text date time date-time unknown].each do |type|
      value = "\xFF".dup.force_encoding(Encoding::UTF_8)
      expect(pointers("vCardProps" => [["x-custom", {}, type, value]])).to include("/vCardProps/0/3")
    end
  end
end
