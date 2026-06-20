# Security Policy

## Supported Versions

The latest release of Open Comic for macOS is actively supported. Older releases do not receive security fixes.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report vulnerabilities via a **private security advisory**:

> <https://github.com/greatdeepband/OpenComicOSX/security/advisories/new>

GitHub will keep the report private until a fix is released. We aim to acknowledge reports within 5 business days.

## Scope

- The Open Comic macOS application
- The bundled `unar` and `lsar` command-line tools (used for CBR/CB7 extraction)

Out of scope: third-party libraries used as Swift Package dependencies (report those upstream).

## Release Integrity

All releases are notarized and signed with a Developer ID certificate. You can verify a download with:

```sh
spctl --assess --type exec -vv /Applications/Open\ Comic.app
```
