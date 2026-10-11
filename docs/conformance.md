# Conformance

`bundle exec rake fixtures` downloads the RFCXML documents listed in
`script/rfc_sources.json`, checks their SHA-256 digests, and extracts examples into
ignored `tmp/rfc/fixtures/`. `bundle exec rake` prepares these inputs before testing.
Neither original documents nor extracted examples are committed or packaged.
A missing source, failed download, changed source digest, missing example, or
changed corpus fingerprint fails the task. Cached sources are checked on every run.

The corpus contains 97 entries: all 42 JSON figures in RFC 9553, all 53 paired
conversion figures and the standalone JSPTR example in RFC 9555, and the
ContactCard/get response Card from RFC 9610. RFC 9982 contains no sourcecode
examples; explicit tests cover its optional UID and version rules. ABNF and JMAP
protocol envelopes are outside the Card example corpus.

Each extracted entry records its RFC section, figure, original source blocks, and
every preparation correction in `manifest.json`. Original copyright/author notices
remain in the downloaded XML. A generated LICENSE uses the IETF Trust short
notification permitted by Legal Provisions sections 4.e and 6.d for the Revised
BSD terms. These downloaded materials remain separate from the MIT Ruby library.

## Example preparation

Property fragments receive JSON braces and a minimal Card envelope; vCard fragments
receive BEGIN/END, VERSION, and an omitted UID. The supplied UID is test scaffolding,
not a library conversion behavior. Presentation continuations are unfolded.

Specific corrections are limited to:

- RFC 9553 figure 18: put `full` inside Name; figures 20 and 39: supply omitted Card
  envelope fields; figure 35: join a presentation-wrapped data URI; figure 36:
  close the directories object.
- RFC 9555 figure 5: correct the LANGUAGE delimiter; figure 9: rename the second
  duplicate `year` key to `day`; figures 20 and 37: remove presentation ellipses;
  figure 47: remove a trailing comma.
- RFC 9555 figure 50: replace a vendor-name solidus forbidden by RFC 9553 with a
  hyphen and add the PROP-ID referenced by the JSPTR path.
- RFC 9555 figures 27 and 40: include the optional group-preservation metadata
  omitted from the JSON example; figure 51: remove the eighth empty N component.
- RFC 9555 figure 53: correct ADR number/name positions to 10/11, following the
  RFC 9554 definitions and reported erratum 8786.
- RFC 9610 figure 2: select its response Card, omit the JMAP-only `id` and
  `addressBookIds`, and supply the omitted Card envelope.

No example is silently skipped because a parser rejects it. JSON round trips
compare every field. Conversion comparisons canonicalize arbitrary generated Ids
and their references, optional `@type` and default properties, unordered name and
address components, and the separately preserved vCard VERSION property.

## Errata review

Checked 2026-10-11: [RFC 9553](https://www.rfc-editor.org/errata/rfc9553) has reported
errata 8263–8267 and [RFC 9555](https://www.rfc-editor.org/errata/rfc9555) has reported
errata 8555 and 8786; none of these is verified. The corrections above follow
unambiguous JSON syntax and normative field definitions, not the status of a
reported erratum. The proposed CryptoKey kind values in erratum 8267 are not
adopted as registered enum values. [RFC 9982](https://www.rfc-editor.org/errata/rfc9982)
had no matching errata.

## Registry maintenance

The authored `data/types.yml` and `data/enums.yml` are the runtime registry
metadata. `bundle exec ruby script/update_registry.rb` checks every registered
JSContact type, property, reserved name, enum value and version, plus the script
codes from the IANA Language Subtag Registry, against SHA-256-pinned downloads.
The source URLs, hashes and review date are in `script/registry_sources.json`.
Raw registries stay under ignored `tmp/registry/sources/` and never enter the gem.

`bundle exec ruby script/update_registry.rb --refresh` downloads the current
registries and audits them before updating the source hashes. If coverage changed,
it fails and writes `tmp/registry/review.txt`; review those changes and update the
authored metadata before retrying. It never imports unreviewed property rules.

Two current IANA table discrepancies are checked explicitly: Title.organizationId
is listed as String instead of the Id required by RFC 9553 section 2.2.5, and
Card.preferredLanguages as String[LanguagePref] instead of Id[LanguagePref] in
section 2.3.4. The library follows the narrower normative RFC definitions.
RFC 9610's reserved Card `id`/`addressBookIds` and Media `blobId` names are included.

## Conversion checks

`bundle exec rake test` converts all 54 downloaded vCard inputs to JSContact and
compares each result with its RFC expectation. It also converts every expected
Card to vCard and back. Comparisons retain RFC 9555 `vCardParams`, `vCardName`,
unmatched properties, and vendor extension values. Only the documented default,
generated Id, and ordering equivalences above are normalized.

The previous calcard comparison and Rust dependency stack have been removed.
These checks use externally specified expected values and this library's Ruby
converter; they are not an independent implementation comparison. The historical
comparison and license findings are recorded in [provenance.md](provenance.md).
