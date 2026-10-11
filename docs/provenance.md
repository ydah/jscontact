# Implementation provenance and dependency review

Reviewed 2026-10-12. This project licenses its Ruby implementation under MIT.
Protocol facts, externally downloaded test data, and independently installed
libraries are recorded separately below. This review does not establish that no
external source code was ever read, or prove the provenance of every expression.

## Implementation and metadata

| Files | Specification requirements |
| --- | --- |
| `lib/jscontact.rb`, `lib/jscontact/validator.rb`, `types.rb`, `model.rb` | RFC 9553 sections 1 and 2: property types, required fields, values, references and contact objects |
| `lib/jscontact/patch_object.rb`, `localization.rb` | RFC 9553 section 2.7: PatchObject and localization rules |
| `lib/jscontact/vcard/` | RFC 9555: conversion between the RFC 9553 contact model and vCard properties |
| `data/types.yml`, `data/enums.yml` | RFC 9553/9555 property identifiers and constraints, RFC 9610 reserved names, RFC 9982 version/UID rules and IANA identifiers |

The YAML files are authored validation tables: property/type identifiers, required
flags, defaults, relationships, enumerated values and specification section
references. They are not imported CDDL/ABNF grammars, copied reference-library
schemas, or RFC example corpora. The registry audit compares these facts with
pinned IANA downloads without copying source documents into the package.

The existing development record identifies reviews of
[Java jscontact-tools](https://github.com/consiglionazionaledellericerche/jscontact-tools)
(AGPL-3.0) and [Perl Text::JSContact](https://github.com/brong/Text-JSContact)
(Perl licensing), and execution of calcard 0.3.2 as a conversion oracle. The record
does not identify every file inspected and does not support a claim that external
source code was never viewed. The Rust command wrapper only invoked calcard's
public conversion API; it was not a port of calcard's implementation. No specific
copied runtime fragment was identified during this review. That finding is not an
independent legal audit or a complete reconstruction of the development history.

## Dependency changes

The calcard comparison job, original CLI wrapper, Cargo manifest and lockfile
were removed on 2026-10-12. calcard 0.3.2 itself offers Apache-2.0 OR MIT. Its
transitive stack was not MIT-only: `sha1_smol` 1.0.1 uses BSD-3-Clause, and
`unicode-ident` 1.0.24 combines MIT/Apache alternatives with Unicode-3.0 terms.
These findings came from the installed crates' manifests and license files.
No Rust toolchain or comparison library is now required by this project.

Rubocop was also removed from development dependencies. Its transitive
`unicode-display_width` 3.3.0 and `unicode-emoji` 4.3.0 declare MIT for their code
but separately identify Unicode data terms in their README files. Gem metadata
alone therefore does not establish MIT-only terms for all bundled material.
Ruby syntax checks, RSpec and RBS remain in the verification workflow.

Runtime dependencies are `tzinfo` (MIT), its `concurrent-ruby` dependency (MIT),
and `json` (Ruby standard library exception). Optional vCard support uses the
MIT `jcard_jcal` gem. Added runtime/development libraries and their transitive
dependencies must offer MIT terms. Ruby runtimes, standard libraries and bundled
tools, including JSON, IRB, REXML and RBS, are explicit project-policy exceptions.
An MIT option in a dual license may be selected, but it does not waive separate
notices for bundled components or data. Installed gemspec metadata and license
files are reviewed separately from the project license.

## Test material and retained coverage

RFC documents, extracted examples and IANA registries remain only in ignored
`tmp/` directories, with pinned hashes and applicable notices. They retain their
own terms, are not relicensed as MIT, and are excluded by the gem package allowlist.

All 97 RFC JSON examples and both directions of all 54 vCard conversion pairs
remain covered. Expected results come from the external RFC corpus; full metadata
and opaque extension preservation are checked. The comparisons normalize only
documented generated identifiers, defaults and ordering equivalences. These are
conformance and round-trip checks, not an independent converter comparison.

`bundle exec ruby script/check_licenses.rb` checks the resolved Bundler graph
against this policy in CI and release jobs. It has an explicit standard-library
allowlist, selects diff-lcs's documented MIT alternative, rejects missing or
unreviewed license metadata, and blocks the known Unicode-data gems above. It
does not replace reviewing the actual contents and notices of a new dependency.
