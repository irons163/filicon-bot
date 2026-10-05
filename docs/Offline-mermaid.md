# Public offline Mermaid resources

Filicon now bundles the clean public **Mermaid 11.16.0** IIFE distribution and
its dependency notices. This is a resource and verification foundation; it does
not yet replace the three-kind native diagram parser or its viewer. Full public
engine rendering and transcript/viewer integration remain required work.

## Reference and provenance

The reference is `grok-bot-0.18-reconstructed` at
`a9f633e09d49a85829b8236331b9e21f7e612634`. Its recovered `mermaid.tsx` calls
`initialize`, `parse` and `render`, using strict security and light/dark themes.
It refers to an unavailable opaque `mermaid.core-CYC_FcEu.js` asset. The recovered
application contract declares `^11.16.0`, but its root lockfile does **not** pin
a Mermaid dependency tree. A clean public package is a replacement candidate,
not proof of the original version, shipped bytes or exact layout.

The imported [public archive](https://registry.npmjs.org/mermaid/-/mermaid-11.16.0.tgz)
is verified with SHA-512 before reading entries. The engine is copied unchanged,
including its bundled copyright notices; no dependency installation, package
scripts, opaque recovered shims or source-map execution is involved.

The archive's `mermaid.min.js.map` identifies 59 outer package/version paths and
12 additional identities inside pre-bundled parser sources. Its 32 parser source
entries match the public `@mermaid-js/parser` 1.2.0 archive byte-for-byte. That
parser's own notice is included too: 72 component notices, plus Mermaid's MIT
license and engine. This proves the inspected public distribution's provenance,
not the reference's missing shipped tree. Patched `roughjs` and peer-resolution
suffixes remain recorded in the source identities rather than being presented
as standalone registry code equivalence.

`scripts/mermaid-vendor-lock.json` records exact archive integrities, source-map
hash, package versions and original notice paths/hashes. The notices are copied
without rewriting. This includes Apache, BSD, ISC and MIT notices and DOMPurify's
original dual-license text. `khroma` has no license field in its package metadata;
its original MIT notice is retained rather than inventing a metadata value.
Only notice documents are imported from dependency archives, never their code.

## Reproduction and validation

The checked-in resource folder is sufficient for an ordinary build. Re-import
requires the exact Mermaid archive and a local directory holding each archive
under the `cacheFile` name in the vendor lock. Its `source` and `integrity` fields
identify the pinned public inputs; the importer itself never downloads them.

Repository attributes disable line-ending conversion, filters and identifier
expansion for both offline vendor folders. An isolated Git index/export test
with `core.autocrlf=true` checks every Mermaid resource remains byte-identical;
it never commits, invokes user hooks or changes this repository's Git settings.

```sh
ruby scripts/import-mermaid.rb /explicit/path/mermaid-11.16.0.tgz /explicit/path/notice-archives
ruby scripts/verify-mermaid.rb Sources/FiliconRichContent/Resources/Mermaid
FILICON_MERMAID_IMPORT_ARCHIVE=/explicit/path/mermaid-11.16.0.tgz \
FILICON_MERMAID_NOTICE_ARCHIVES=/explicit/path/notice-archives ruby scripts/test-mermaid.rb
```

Every input archive, selected entry and destination is checked before any vendor
write. Missing or modified archives, an altered lock, duplicate entries,
symlinked destinations and unexpected existing vendor files reject the import.
Import-specific tests use a temporary repository fixture, not the vendor folder;
they skip without the two explicit local-input environment variables. Resource
tests remain available offline.

The resource manifest is pinned in `OfflineMermaidResources` and the package
verifier. Every engine/license/notice file is required and hashed before the
loader exposes the engine string. The loader rejects symlinked files and both
notice-directory levels, limits manifest/per-file/total bytes, and fails closed
when a preferred bundle is damaged instead of borrowing another installation.
It avoids SwiftPM's trapping generated accessor when a whole bundle is missing.
Exposing this verified string does not evaluate it or grant application tools.

Xcode and standalone packaging include the same SwiftPM resource directory.
`verify-package.sh` now checks these resources as well as the existing math,
executable, entitlement and deep-signature checks. Final evidence is recorded in
[the completion audit](Parity-completion-audit.md).

## Remaining boundary

No transcript render, new graph language, full-engine SVG, browser runtime,
navigation or active content is enabled by this resource-only increment. The
existing bounded native renderer remains unchanged. Engine isolation, safe SVG
handling, serialized/cancellable rendering, lifecycle and viewer integration
must be implemented and verified before calling the UI gap resolved. Neither
the public archive nor the dependency notices establish opaque-byte or
pixel-identical parity. `UI-04`, human/minimum-macOS checks and external/release
acceptance remain partial.
