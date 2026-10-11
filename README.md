<h1 align="center">JSContact</h1>

<p align="center">JSON contact cards with validation and vCard conversion.</p>

<p align="center">
  <a href="https://rubygems.org/gems/jscontact"><img src="https://img.shields.io/gem/v/jscontact" alt="Gem version"></a>
  <a href="https://github.com/ydah/jscontact/actions/workflows/main.yml"><img src="https://github.com/ydah/jscontact/actions/workflows/main.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/Ruby-%3E%3D%203.3-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby 3.3 or later"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://ydah.github.io/jscontact/">Website</a> &middot;
  <a href="#installation">Installation</a> &middot;
  <a href="#quick-start">Quick start</a> &middot;
  <a href="#supported-scope">Supported scope</a> &middot;
  <a href="#development">Development</a> &middot;
  <a href="#license">License</a>
</p>

Parse, validate, build, and convert JSContact contact cards in Ruby. Supports
[RFC 9553](https://www.rfc-editor.org/rfc/rfc9553),
[RFC 9555](https://www.rfc-editor.org/rfc/rfc9555), and
[RFC 9982](https://www.rfc-editor.org/rfc/rfc9982).

## Features

- Build typed JSContact 2.0 cards and read existing 1.0 cards.
- Apply patches and localizations while preserving vendor extensions.
- Convert vCard 4.0 through an optional jcard_jcal integration.

Unknown properties, vendor extensions, and map identifiers survive JSON round
trips. New cards use JSContact 2.0; reading a 1.0 card keeps its version until you
explicitly upgrade it.

## Installation

Requires Ruby 3.3 or later. CI also tests JRuby and TruffleRuby on Linux and macOS.

Add the gem to your Gemfile:

```ruby
gem "jscontact"
# Add only when using the optional vCard converter:
gem "jcard_jcal", "~> 0.1.0"
```

Then run `bundle install`.

The JSON API depends on `json` and `tzinfo`. On systems without a zoneinfo database
(such as Windows), also install `tzinfo-data` for time zone and country validation.

## Quick start

```ruby
require "jscontact"

card = JSContact::Card.build do |contact|
  contact.name = { full: "Mina Sample" }
  contact.add_email(address: "mina@example.test", contexts: { work: true })
  contact["example.test:customer"] = { "number" => 42 }
end

card.name.full                    # => "Mina Sample"
card.emails["e1"].address         # => "mina@example.test"
card.emails["e1"].label = "Desk" # updates the parent card
card.to_h                        # independent, deep copy
json = card.to_json              # validates before serializing
copy = JSContact.parse(json)
```

`JSContact` and `Jscontact` refer to the same module. The schema defines typed
classes such as `Name`, `Address`, and `EmailAddress`; nested accessors return typed
views. `[]` and `[]=` also accept unknown property names. Camel-case property
accessors have snake-case aliases, for example `preferred_languages`.

`Card.new(hash)` copies the input and permits incomplete data while building a
card. Use `strict: true` to validate immediately. Constructors accept symbol keys
and normalize them to strings; duplicate normalized keys are rejected.

`to_h` preserves absent default properties; accessors expose their defaults.
`Card.build(explicit_types: true)` includes optional nested `@type` members when
exporting. Nested objects serialized on their own include their required `@type`.
Instances are mutable; give each concurrent worker its own card.

## Validation and versions

```ruby
card = JSContact.parse(json, strict: false)
card.valid?
card.warnings.each { |violation| puts "#{violation.pointer}: #{violation.message}" }
card.validate! # raises JSContact::ValidationError if invalid

upgraded = JSContact.upgrade(card) # validates, copies, and sets version to "2.0"
```

`parse` is strict by default. Lenient parsing retains schema violations in
`errors` (also available as `warnings`); malformed JSON, duplicate keys, unsupported
Ruby values, and resource-limit violations still raise. Serialization is always
strict. `ValidationError#errors` contains every collected `Violation`, with a JSON
Pointer and message; the empty pointer identifies the document root.

Version 1.0 requires `uid`; version 2.0 permits it to be absent. Upgrading changes
only the version, without inventing a UID or renumbering map identifiers. Unknown
properties with valid names are preserved. Unknown enum values are reported as
violations unless they use the vendor extension syntax.

## Patches and localizations

```ruby
card.localizations = { "ja" => { "name/full" => "サンプル ミナ" } }
japanese = card.localized("ja")

patched = JSContact::PatchObject.new({ "name/full" => "Mina Updated" }).apply(card.to_h)
```

Patch keys are JSON Pointers without the leading slash. `nil` deletes an object
member; array entries can be replaced but cannot be inserted or removed. Escapes,
parent paths, overlapping paths, resulting types, and required properties are
checked before returning a result. Neither the patch nor its target is modified.
Schema validation applies when the target has a recognized `@type`; untyped
objects receive JSON structure validation.

`localized` matches language tags without case sensitivity, applies the selected
patch to a copy, removes its localization map, and sets its language. If no patch
matches, it returns an unchanged copy. Patches cannot modify `localizations` itself.

## vCard conversion

```ruby
require "jscontact/vcard"

text = JSContact::VCard.from_jscontact(card)
restored = JSContact::VCard.to_jscontact(text) # JSContact 2.0
```

Only the optional entrypoint loads `jcard_jcal`. Conversion accepts exactly one
vCard 4.0. A missing UID stays absent when converting to JSContact 2.0. Requesting
`version: "1.0"` emits a deprecation warning and supplies a stable UID if necessary.

| RFC 9555 rules | Support |
| --- | --- |
| Sections 2.2–2.3: value types and parameters | Both directions, including PROP-ID, ALTID, LANGUAGE, and JSCOMPS |
| Sections 2.4–2.6: general properties, identification, delivery addresses | Both directions, including phonetic values |
| Sections 2.7–2.10: communication, geography, organizations, personal information | Both directions |
| Sections 2.11–2.14: explanatory, security, calendar, and extended properties | Both directions |
| Section 2.15: unmatched properties and parameters | Retained as `vCardProps`, `vCardParams`, and `vCardName` |
| Section 3: JSContact to vCard | Native properties plus JSPROP/JSPTR for otherwise unrepresentable data |

Conversion preserves data, rather than the original text's property order,
folding, or choice of equivalent representation. Date forms without a JSContact
equivalent and unmatched birth/death place properties are retained in `vCardProps`.
Timestamp conversion preserves leap seconds. Timestamps without a UTC offset
remain in `vCardProps` or `vCardParams`, since no UTC instant can be inferred.

JSContact date fields use the Gregorian calendar even when `calendarScale` names
another calendar. The converter preserves non-Gregorian vCard CALSCALE properties
in `vCardProps`; it does not perform calendar arithmetic. In the other direction,
it emits a Gregorian native date and retains non-Gregorian metadata through JSPROP.
The underlying vCard parser checks Gregorian date validity, so dates from an
unsupported calendar that fail those checks raise `ConversionError`.

A top-level unknown property whose value is JSON `null` cannot be represented by
JSPROP: its PatchObject semantics mean deletion. Conversion raises
`ConversionError` with the property pointer instead of dropping it. Nested nulls
inside a retained object or array are supported. Ordinary JSON round trips retain
all null values.

## Supported scope

| Feature | Status |
| --- | --- |
| RFC 9553 object models, validation, JSON generation | Supported |
| RFC 9982 JSContact 2.0 and optional UID | Supported; 1.0 is retained when read |
| PatchObject and localizations | Supported |
| RFC 9555 and RFC 9554 vCard 4.0 conversion | Supported as described above |
| Unknown properties and vendor JSON | Preserved, subject to valid names and I-JSON constraints |
| JMAP for Contacts | Card data supported; protocol operations are outside scope |
| vCard 2.1/3.0, CardDAV sync, RDAP profiles, locale-specific display formatting | Outside scope |

## Resource limits

These options apply to `parse` and model constructors. Exceeding a limit raises
`LimitError`, including in lenient mode.

| Option | Default | Applies to |
| --- | --- | --- |
| `max_input_size` | 16 MiB | JSON input bytes in `parse` |
| `max_depth` | 32 | Nested JSON objects and arrays, including vendor values |
| `max_map_size` | 10,000 | Schema-defined maps and arrays |
| `max_data_uri_size` | 1 MiB | Estimated decoded data URI size |
| `max_patches` | 1,000 | Total localization patches, or entries in a PatchObject |

```ruby
JSContact.parse(json, max_input_size: 1_048_576, max_depth: 16, max_map_size: 500)
```

The gem never fetches resource URIs or resolves linked contacts. vCard text parsing
also uses `jcard_jcal`'s own parser limits. See [SECURITY.md](SECURITY.md) for reporting
vulnerabilities.

## Development

```sh
bundle install
bundle exec rake                      # fetch and verify external RFC inputs, then test
COVERAGE=1 bundle exec rake            # minimum 90% line coverage
bundle exec rbs -I sig validate
bundle exec ruby script/check_syntax.rb
bundle exec ruby script/check_licenses.rb
bundle exec ruby script/benchmark.rb   # time, allocation and RSS measurements at limits
bundle exec ruby script/update_registry.rb           # verify pinned IANA registry coverage
bundle exec ruby script/update_registry.rb --refresh # audit current IANA data and update pins
```

The suite checks 97 generated RFC examples, both directions of 54 vCard conversion
pairs, malformed input, patches, limits, and deterministic random round trips.
See [conformance notes](docs/conformance.md) for extraction corrections, reported
errata, and the current comparison scope.
The [boundary measurements](docs/performance.md) explain the default limits.

RFC originals, extracted examples, and IANA downloads
live only in ignored `tmp/` directories. Downloads retain their applicable notices;
RFC source hashes and the generated corpus fingerprint are checked before testing.
The packaged gem contains library code, original schema metadata, RBS, and user
documentation, excluding test corpora and third-party source code.

## Release

Configure RubyGems Trusted Publishing for owner `ydah`, repository `jscontact`,
workflow `release.yml`, and GitHub environment `release`. After checks pass, update
the gem version and CHANGELOG, then push the matching `vVERSION` tag. The workflow
tests, builds, publishes through OIDC, and creates a GitHub release from that
version's CHANGELOG entry. A version already on RubyGems is not published again.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/ydah/jscontact/issues). See [Development](#development) for the checks to run before submitting a change. Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

The Ruby library is available under the [MIT License](LICENSE.txt). Added runtime
and development libraries must offer MIT terms, including transitive dependencies;
Ruby runtimes, standard libraries, and bundled tools are explicit exceptions.
External RFC and registry test inputs retain their notices and are not included
in the gem. See [provenance and dependency review](docs/provenance.md).
