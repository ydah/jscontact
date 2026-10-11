# Security

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/ydah/jscontact/security/advisories/new).
Please include a minimal reproducer and the affected gem and Ruby versions.

The library treats documents as data. It does not retrieve contact URIs or execute embedded content.

Dependency policy: added runtime and development libraries, including transitive
dependencies, must offer MIT terms. Ruby runtimes, standard libraries, and bundled
tools are explicit exceptions. Externally downloaded RFC/registry test data retain
their own notices and stay outside the repository and gem package. Dependency
license review does not constitute a cryptographic or application security audit.
See [provenance and dependency review](docs/provenance.md) for the review scope.
