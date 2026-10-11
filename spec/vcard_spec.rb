# frozen_string_literal: true

require "spec_helper"
require "jscontact/vcard"

RSpec.describe Jscontact::VCard do
  def vcard(*lines)
    (["BEGIN:VCARD", "VERSION:4.0"] + lines + ["END:VCARD", ""]).join("\r\n")
  end

  def convert(*lines, **options)
    described_class.to_jscontact(vcard(*lines), **options).to_h
  end

  it "converts explicit identifiers, communication properties and parameters" do
    result = convert("FN:Test Contact", "EMAIL;PROP-ID=office;TYPE=work;PREF=2;X-KEEP=ok:contact@example.test",
                     "TEL;PROP-ID=mobile;TYPE=home,cell,voice:555-0100")
    expect(result).not_to have_key("uid")
    expect(result["emails"]["office"]).to eq("address" => "contact@example.test", "contexts" => { "work" => true },
                                             "pref" => 2, "vCardParams" => { "x-keep" => "ok" })
    expect(result["phones"]["mobile"]).to include("number" => "555-0100", "contexts" => { "private" => true },
                                                  "features" => { "mobile" => true, "voice" => true })
  end

  it "preserves unmapped vCard properties" do
    result = convert("FN:Test", "item9.X-EXPERIMENT;X-PARAM=yes:literal\\,value", "GENDER:O;description")
    expect(result["vCardProps"]).to include(["x-experiment", { "x-param" => "yes", "group" => "item9" }, "unknown", "literal\\,value"],
                                            ["gender", {}, "text", %w[O description]])
    expect(described_class.from_jscontact(Jscontact::Card.new(result))).to include("item9.X-EXPERIMENT;X-PARAM=yes:literal\\,value")
  end

  it "converts localized alternatives without losing their identity" do
    result = convert("LANGUAGE:en", "FN:Sample", "TITLE;PROP-ID=t;ALTID=1:Coordinator",
                     "TITLE;PROP-ID=t;ALTID=1;LANGUAGE=ja:調整役")
    expect(result.dig("titles", "t", "name")).to eq("Coordinator")
    expect(result.dig("localizations", "ja", "titles/t/name")).to eq("調整役")
  end

  it "preserves ordered name components, separators and nested extensions through both directions" do
    data = { "@type" => "Card", "version" => "2.0", "name" => { "components" => [
      { "kind" => "given", "value" => "Sample", "test.example:extra" => 7 },
      { "kind" => "separator", "value" => " / " }, { "kind" => "surname", "value" => "Person" }
    ], "isOrdered" => true }, "test.example:flag" => { "active" => true } }
    text = described_class.from_jscontact(Jscontact::Card.new(data))
    expect(text).to include("JSCOMPS=", "JSPROP;JSPTR=")
    expect(described_class.to_jscontact(text).to_h).to eq(data)
  end

  it "rejects multiple input cards" do
    expect { described_class.to_jscontact(vcard("FN:One") + vcard("FN:Two")) }.to raise_error(Jscontact::ConversionError)
  end

  it "warns and generates a stable UID only for the deprecated version" do
    text = vcard("FN:Legacy")
    expect { described_class.to_jscontact(text, version: "1.0") }.to output(/1\.0/).to_stderr
    a = nil
    b = nil
    expect { a = described_class.to_jscontact(text, version: "1.0").to_h }.to output.to_stderr
    expect { b = described_class.to_jscontact(text, version: "1.0").to_h }.to output.to_stderr
    expect(a["uid"]).to match(/\Aurn:uuid:/)
    expect(a["uid"]).to eq(b["uid"])
  end
end

RSpec.describe Jscontact::VCard, "mapping details" do
  def convert(*lines)
    described_class.to_jscontact((["BEGIN:VCARD", "VERSION:4.0", "FN:Protocol Sample"] + lines + ["END:VCARD", ""]).join("\r\n")).to_h
  end

  it "maps every resource category and preserves preferences" do
    lines = {
      "SOURCE" => %w[directories entry], "PHOTO" => %w[media photo], "LOGO" => %w[media logo],
      "SOUND" => %w[media sound], "ORG-DIRECTORY" => %w[directories directory],
      "CONTACT-URI" => %w[links contact], "URL" => ["links", nil], "KEY" => ["cryptoKeys", nil],
      "CALADRURI" => ["schedulingAddresses", nil], "CALURI" => %w[calendars calendar], "FBURL" => %w[calendars freeBusy]
    }
    lines.each do |property, (map, kind)|
      result = convert("#{property};PROP-ID=ref;PREF=4;MEDIATYPE=text/plain:https://example.test/resource")
      expect(result[map]["ref"]).to include("uri" => "https://example.test/resource", "pref" => 4)
      if property == "CALADRURI"
        expect(result[map]["ref"].dig("vCardParams", "mediatype")).to eq("text/plain")
      else
        expect(result[map]["ref"]["mediaType"]).to eq("text/plain")
      end
      expect(result[map]["ref"]["kind"]).to eq(kind)
      expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
    end
  end

  it "maps organization units, sorting, roles, personal information and authored notes" do
    result = convert("team.ORG;PROP-ID=org;SORT-AS=Sample,Research:Sample Company;Research Unit",
                     "team.ROLE;PROP-ID=role:Investigator", "TITLE;PROP-ID=title:Engineer",
                     "EXPERTISE;PROP-ID=skill;INDEX=3;LEVEL=average:Geology", "HOBBY;PROP-ID=hobby;LEVEL=low:Painting",
                     "INTEREST;PROP-ID=interest;LEVEL=high:Ecology",
                     "NOTE;PROP-ID=note;AUTHOR-NAME=Reader;AUTHOR=\"mailto:r@example.test\";CREATED=20261011T010203Z:Remark")
    expect(result.dig("organizations", "org", "units")).to eq([{ "name" => "Research Unit", "sortAs" => "Research" }])
    expect(result.dig("titles", "role", "organizationId")).to eq("org")
    expect(result.dig("personalInfo", "skill")).to include("kind" => "expertise", "level" => "medium", "listAs" => 3)
    expect(result.dig("notes", "note")).to include("created" => "2026-10-11T01:02:03Z", "author" => { "name" => "Reader", "uri" => "mailto:r@example.test" })
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "maps birth and death dates, places, wedding dates and reduced dates" do
    result = convert("BDAY:20000229T123456+09", "BIRTHPLACE:Somewhere", "DEATHDATE:20251010",
                     "DEATHPLACE;VALUE=uri:geo:1,2", "ANNIVERSARY:--0708")
    objects = result.fetch("anniversaries").values.to_h { |anniversary| [anniversary["kind"], anniversary] }
    expect(objects["birth"]["date"]).to eq("@type" => "Timestamp", "utc" => "2000-02-29T03:34:56Z")
    expect(objects["birth"]["place"]).to eq("full" => "Somewhere")
    expect(objects["death"]["date"]).to eq("year" => 2025, "month" => 10, "day" => 10)
    expect(objects["wedding"]["date"]).to eq("month" => 7, "day" => 8)
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
    expect(convert("BDAY:1980").fetch("anniversaries").values.first["date"]).to eq("year" => 1980)
  end

  it "keeps temporal values that have no JSContact equivalent" do
    %w[T123000 --07 ---08 20000229T1234].each do |value|
      expect(convert("BDAY:#{value}").fetch("vCardProps").any? { |prop| prop.first == "bday" }).to be(true)
    end
  end

  it "merges grouped geographic properties and only converts whole-hour UTC offsets" do
    result = convert("loc.ADR;PROP-ID=place;CC=JP;TYPE=billing:;;Road;City;Region;123;Country",
                     "loc.GEO:geo:12,34", "loc.TZ;VALUE=utc-offset:+0900", "TZ;VALUE=utc-offset:+0530")
    expect(result.dig("addresses", "place")).to include("countryCode" => "JP", "coordinates" => "geo:12,34",
                                                        "timeZone" => "Etc/GMT-9", "contexts" => { "billing" => true })
    expect(result["vCardProps"].any? { |prop| prop[0] == "tz" }).to be(true)
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "converts all name/address components with ordering, secondary names and phonetics" do
    name = { "components" => [
      { "kind" => "surname2", "value" => "Second", "phonetic" => "second" },
      { "kind" => "given", "value" => "First", "phonetic" => "first" },
      { "kind" => "generation", "value" => "II" }, { "kind" => "credential", "value" => "PhD" }
    ], "isOrdered" => true, "defaultSeparator" => ",; ", "phoneticSystem" => "ipa", "phoneticScript" => "Latn" }
    address = { "components" => Jscontact::VCard::Structured::ADDRESS_KINDS.uniq.map { |kind| { "kind" => kind, "value" => kind } },
                "isOrdered" => true, "full" => "Formatted", "timeZone" => "Etc/UTC" }
    input = { "@type" => "Card", "version" => "2.0", "name" => name, "addresses" => { "address" => address } }
    result = described_class.to_jscontact(described_class.from_jscontact(input)).to_h
    expect(result).to eq(input)
  end

  it "uses labels, phone features, service usernames and preferred languages" do
    result = convert("a.TEL;PROP-ID=phone;TYPE=cell,text,custom:123", "a.X-ABLabel:Personal mobile",
                     "SOCIALPROFILE;PROP-ID=social;VALUE=text;SERVICE-TYPE=Chat:reader", "IMPP;PROP-ID=im;USERNAME=reader:xmpp:r@example.test",
                     "LANG;PROP-ID=lang;TYPE=home;PREF=1:ja", "NICKNAME;PROP-ID=nick:Reader,Writer",
                     "GRAMGENDER:NEUTER", "PRONOUNS;PROP-ID=pronouns;PREF=2:they/them")
    expect(result.dig("phones", "phone", "label")).to eq("Personal mobile")
    expect(result.dig("phones", "phone", "vCardParams", "type")).to eq("custom")
    expect(result.dig("onlineServices", "social")).to include("user" => "reader", "service" => "Chat")
    expect(result.dig("onlineServices", "im")).to include("vCardName" => "impp", "user" => "reader")
    expect(result.fetch("nicknames").values.map { |object| object["name"] }).to eq(%w[Reader Writer])
    expect(result.dig("speakToAs", "grammaticalGender")).to eq("neuter")
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "supports grouped contacts, relations, keywords and metadata" do
    result = convert("KIND:group", "UID:urn:example:team", "MEMBER:urn:example:person", "RELATED;TYPE=friend:urn:example:friend",
                     "RELATED;VALUE=text:Contact desk", "CATEGORIES:Code,Science", "CREATED:20251011T000000Z",
                     "REV:20261011T000000Z", "PRODID:Unit Test")
    expect(result["members"]).to eq("urn:example:person" => true)
    expect(result["keywords"]).to eq("Code" => true, "Science" => true)
    expect(result.dig("relatedTo", "Contact desk", "relation")).to eq({})
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "preserves localized structured values and extensions when exporting" do
    input = { "@type" => "Card", "version" => "2.0", "language" => "en", "name" => { "full" => "Test" },
              "titles" => { "job" => { "name" => "Editor" } },
              "localizations" => { "ja" => { "name/full" => "テスト", "titles/job/name" => "編集者" } } }
    text = described_class.from_jscontact(input)
    expect(text).to include("LANGUAGE=ja", "ALTID=")
    expect(described_class.to_jscontact(text).to_h).to eq(input)
  end

  it "applies JSPROP after native properties and rejects invalid or ambiguous patches" do
    result = convert('JSPROP;JSPTR="name/full":"Patched"', 'JSPROP;JSPTR="test.example:flag":true')
    expect(result.dig("name", "full")).to eq("Patched")
    expect(result["test.example:flag"]).to be(true)
    expect { convert("JSPROP;JSPTR=name:{}", 'JSPROP;JSPTR="name/full":"Conflict"') }.to raise_error(Jscontact::ValidationError)
    expect { convert("JSPROP;JSPTR=name:{}", "JSPROP;JSPTR=name:{}") }.to raise_error(Jscontact::ConversionError)
    expect { convert("JSPROP;JSPTR=name:invalid") }.to raise_error(Jscontact::ConversionError)
    expect { convert("N:Test;A;;;", 'JSPROP;JSPTR="name/components/0/value":"Forbidden"') }.to raise_error(Jscontact::ConversionError)
  end
  it "preserves nested null and rejects top-level null that JSPROP cannot encode" do
    data = { "@type" => "Card", "version" => "2.0", "name" => { "full" => "Nullable", "example.test:unset" => nil } }
    expect(described_class.to_jscontact(described_class.from_jscontact(data)).to_h).to eq(data)
    data["example.test:unset"] = nil
    expect { described_class.from_jscontact(data) }.to raise_error(Jscontact::ConversionError) do |error|
      expect(error.pointer).to eq("/example.test:unset")
    end
  end

  it "preserves a birthplace without inventing the required anniversary date" do
    result = convert("BIRTHPLACE:Small Island")
    expect(result).not_to have_key("anniversaries")
    expect(result["vCardProps"]).to include(["birthplace", {}, "text", "Small Island"])
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "retains invalid JSCOMPS as an unmapped parameter and ignores its ordering" do
    result = convert('N;JSCOMPS=";99":Family;Given;;;')
    expect(result["name"]["isOrdered"]).not_to be(true)
    expect(result.dig("name", "vCardParams", "jscomps")).to eq(";99")
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "does not discard labels on properties without a label counterpart" do
    result = convert("group.N:Family;Given;;;", "group.X-ABLabel:Name label")
    expect(result["vCardProps"]).to include(["x-ablabel", { "group" => "group" }, "text", "Name label"])
  end

  it "rejects ambiguous single-valued parameters and duplicate identifiers" do
    expect { convert("EMAIL;PREF=1,2:mail@example.test") }.to raise_error(Jscontact::ConversionError)
    expect { convert("EMAIL;PROP-ID=bad.id:mail@example.test") }.to raise_error(Jscontact::ConversionError)
    expect { convert("EMAIL;PROP-ID=id:one@example.test", "EMAIL;PROP-ID=id:two@example.test") }.to raise_error(Jscontact::ConversionError)
    expect { described_class.to_jscontact("invalid", version: "9.0") }.to raise_error(Jscontact::ConversionError)
    expect { described_class.from_jscontact(nil) }.to raise_error(Jscontact::ConversionError)
  end
  it "emits native language-specific phonetic alternatives" do
    input = { "@type" => "Card", "version" => "2.0", "language" => "en", "name" => {
      "components" => [{ "kind" => "given", "value" => "Base" }]
    }, "localizations" => { "ja" => { "name/phoneticSystem" => "ipa", "name/components/0/phonetic" => "beis" } } }
    text = described_class.from_jscontact(input)
    properties = JCard.from_vcard(text, registry: described_class::REGISTRY).first.properties("n")
    expect(properties.any? { |property| property.params["language"] == "ja" && property.params["phonetic"] == "ipa" }).to be(true)
    expect(described_class.to_jscontact(text).to_h).to eq(input)
  end

  it "accepts zero-padded positional indexes while rejecting an explicit zero secondary index" do
    ordered = convert('N;JSCOMPS=";01;00":Family;Given;;;')
    expect(ordered["name"]["isOrdered"]).to be(true)
    expect(ordered["name"]["components"].first["kind"]).to eq("given")
    unordered = convert('N;JSCOMPS=";1,0;0":Family;Given;;;')
    expect(unordered["name"]["isOrdered"]).not_to be(true)
  end

  it "validates raw jCard values before converting them" do
    data = { "@type" => "Card", "version" => "2.0", "vCardProps" => [["fn", {}, "text", {}]] }
    expect { described_class.from_jscontact(data) }.to raise_error(Jscontact::ValidationError) do |error|
      expect(error.pointer).to start_with("/vCardProps/0")
    end
  end
  it "matches vCard groups without case sensitivity" do
    result = convert("Team.ORG;PROP-ID=company:Example", "team.ROLE;PROP-ID=role:Lead",
                     "Contact.TEL;PROP-ID=phone:123", "contact.X-ABLabel:Desk",
                     "Place.ADR;PROP-ID=address:;;Street;City;Region;123;Country", "place.GEO:geo:1,2")
    expect(result.dig("titles", "role", "organizationId")).to eq("company")
    expect(result.dig("phones", "phone", "label")).to eq("Desk")
    expect(result.dig("addresses", "address", "coordinates")).to eq("geo:1,2")
  end
  it "always quotes JSPTR and refolds long properties at UTF-8 boundaries" do
    key = "unregistered" * 12
    input = { "@type" => "Card", "version" => "2.0", key => "語" * 100 }
    text = described_class.from_jscontact(input)
    expect(text.gsub(/\r\n[ \t]/, "")).to include("JSPTR=\"#{key}\"")
    expect(text.split("\r\n").all? { |line| line.bytesize <= 75 && line.valid_encoding? }).to be(true)
    expect(described_class.to_jscontact(text).to_h).to eq(input)
  end

  it "requires JSPROP's JSON to be compact" do
    expect { convert('JSPROP;JSPTR="example.test:object":{"key": true}') }.to raise_error(Jscontact::ConversionError, /whitespace/)
    expect(convert('JSPROP;JSPTR="example.test:string":"A B"')["example.test:string"]).to eq("A B")
  end
  it "uses JSPROP for valid JSON data without a native vCard representation" do
    inputs = [
      { "kind" => "group", "members" => { "plain-id" => true, "urn:example:person" => true } },
      { "name" => { "full" => "A\u0000B" } },
      { "notes" => { "n" => { "note" => "A\u0000B" } } },
      { "phones" => { "p" => { "number" => "123", "features" => { "example.test:other" => true }, "contexts" => { "private" => false } } } }
    ]
    inputs.each do |fields|
      data = { "@type" => "Card", "version" => "2.0" }.merge(fields)
      text = described_class.from_jscontact(data)
      expect(described_class.to_jscontact(text).to_h).to eq(data)
      expect(text).not_to include("TYPE=home")
    end
  end

  it "preserves duplicate scalar values without overwriting the primary value" do
    result = convert("UID:urn:example:first", "UID:urn:example:second", "PRODID:First", "PRODID:Second")
    expect(result["uid"]).to eq("urn:example:first")
    expect(result["prodId"]).to eq("First")
    expect(result["vCardProps"]).to include(["uid", {}, "uri", "urn:example:second"], ["prodid", {}, "text", "Second"])
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "merges repeated relations and retains conflicting parameters" do
    result = convert("RELATED;TYPE=friend;PID=1:urn:example:contact", "RELATED;TYPE=colleague;PID=2:urn:example:contact")
    expect(result.dig("relatedTo", "urn:example:contact", "relation")).to eq("friend" => true, "colleague" => true)
    expect(result.dig("relatedTo", "urn:example:contact", "vCardParams")).to eq("pid" => "1")
    expect(result["vCardProps"]).to include(["related", { "type" => "colleague", "pid" => "2" }, "uri", "urn:example:contact"])
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "retains unknown parameters on grammatical gender, date and place independently" do
    result = convert("GRAMGENDER;X-NOTE=yes:neuter", "BIRTHPLACE;PROP-ID=place;X-SOURCE=place:Town",
                     "BDAY;PROP-ID=date;X-SOURCE=date:19900101")
    expect(result.dig("speakToAs", "vCardParams")).to eq("x-note" => "yes")
    birth = result.fetch("anniversaries").values.first
    expect(birth.dig("vCardParams", "x-source")).to eq("date")
    expect(birth.dig("place", "vCardParams", "x-source")).to eq("place")
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "preserves unknown enumeration values as vCard data" do
    result = convert("KIND:x-special", "GRAMGENDER:x-special", "RELATED;TYPE=x-special:urn:example:contact")
    expect(result["vCardProps"]).to include(["kind", {}, "text", "x-special"], ["gramgender", {}, "text", "x-special"])
    expect(result.dig("relatedTo", "urn:example:contact", "vCardParams", "type")).to eq("x-special")
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "retains unsupported vCard calendar dates without interpreting them as Gregorian dates" do
    result = convert("BDAY;CALSCALE=hebrew:57840101", "DEATHDATE;CALSCALE=x-calendar:21000201")
    expect(result).not_to have_key("anniversaries")
    expect(result["vCardProps"]).to include(["bday", { "calscale" => "hebrew" }, "date-and-or-time", "5784-01-01"],
                                            ["deathdate", { "calscale" => "x-calendar" }, "date-and-or-time", "2100-02-01"])
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "exports JSContact date values in the Gregorian calendar and preserves their calendar metadata" do
    [{ "calendarScale" => "hebrew" }, {}].each do |metadata|
      input = { "@type" => "Card", "version" => "2.0", "anniversaries" => {
        "birth" => { "kind" => "birth", "date" => { "year" => 2000, "month" => 1, "day" => 1 }.merge(metadata),
                     "vCardParams" => { "calscale" => "hebrew" } }
      } }
      text = described_class.from_jscontact(input)
      native = JCard.from_vcard(text, registry: described_class::REGISTRY).first.properties("bday").first
      expect(native.params).not_to have_key("calscale")
      expect(native.to_a[3]).to eq("2000-01-01")
      expect(described_class.to_jscontact(text).to_h).to eq(input)
    end
  end

  it "preserves binary64 vendor values through JSON and vCard serialization" do
    bits = "3fa1afd066484c70"
    number = [bits].pack("H*").unpack1("G")
    input = Jscontact.parse('{"@type":"Card","version":"2.0","example.test:number":0.034544479833265807}')
    expect([input.to_h.fetch("example.test:number")].pack("G").unpack1("H*")).to eq(bits)
    text = described_class.from_jscontact(input)
    output = Jscontact.parse(described_class.to_jscontact(text).to_json).to_h
    expect([output.fetch("example.test:number")].pack("G").unpack1("H*")).to eq([number].pack("G").unpack1("H*"))
  end

  it "retains unknown parameters on phonetic alternatives" do
    result = convert("N;ALTID=n:Family;Given;;;", "N;ALTID=n;PHONETIC=ipa;X-NOTE=yes:fam;giv;;;")
    expect(result.dig("name", "components").map { |item| item["phonetic"] }).to eq(%w[fam giv])
    expect(result["vCardProps"]).to include(["n", { "altid" => "n", "phonetic" => "ipa", "x-note" => "yes" }, "text", %w[fam giv] + ["", "", ""]])
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end

  it "retains phonetic components without a matching base component" do
    result = convert("N;ALTID=n:Family;Given;;;", "N;ALTID=n;PHONETIC=ipa:fam;giv,extra;;;")
    expect(result.dig("name", "components").map { |item| item["phonetic"] }).to eq(%w[fam giv])
    expect(result["vCardProps"]).to include(["n", { "altid" => "n", "phonetic" => "ipa" }, "text", ["fam", %w[giv extra], "", "", ""]])
    expect(described_class.to_jscontact(described_class.from_jscontact(result)).to_h).to eq(result)
  end
end
