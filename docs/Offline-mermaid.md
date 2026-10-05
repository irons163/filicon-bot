# Offline Mermaid rendering

Filicon bundles the clean public **Mermaid 11.16.0** IIFE distribution and its
dependency notices. A serialized offline renderer now produces independently
validated SVG for the actual direct and group transcripts and their native
diagram viewer. Eight diagram families have real UI fixtures; unsafe, invalid
or unavailable output stays readable as the original source. This is not proof
of every Mermaid grammar or the reference's missing shipped assets.

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

## Engine and output validation

`OfflineMermaidRenderer` uses a lazily created, nonpersistent, offscreen WebKit
surface. Page JavaScript is disabled; only the verified engine runs in the
native isolated content world. Source is passed as an argument, never embedded
in a script or HTML document. The fixed document has no message handlers,
application tools or opener. Its content security policy denies scripts,
network requests, images, frames, workers and forms; verified offline math fonts
are the only permitted data resources. Navigation, downloads, new windows and
script dialogs are rejected. The service does not create an application window.

Each request initializes strict security, a fixed light/dark theme, deterministic
IDs, a 65,536-byte source limit and 512-edge limit. The secure configuration
list prevents frontmatter from replacing those settings or installing arbitrary
theme CSS. Parsing and rendering use the public engine; `bindFunctions` is never
called. Strict mode alone is insufficient: the actual engine still emits an
external image for an adversarial label. Output must therefore pass a separate
native gate before any consumer receives it.

`MermaidSVG.validated` accepts a bounded SVG shape/style subset, plain XHTML
labels inside `foreignObject`, and static MathML with plain TeX annotations. It
rejects scripts, events, links, images, embedded documents, forms, editable
elements, active SVG animation elements, external resources, CSS escapes/imports
and entity declarations. Direct attribute and inline-style references must
resolve to local IDs; resource-definition cycles are rejected. Stylesheets may
contain unresolved local fragments because the pinned engine emits unused neo
theme rules, but external references remain forbidden. The output has at most
2 MiB, 16,384 nodes, 128 levels and 65,536 bytes per attribute. ViewBox dimensions
must be finite, positive and no greater than 20,000; numeric geometry and shadows
have separate bounds.

Two inert public-engine artifacts are normalized: later duplicate ID attributes
are removed while preserving the first target, and bare `undefined` inline CSS
statements are dropped. No resource, markup capability or network permission is
added. Validated serialization is idempotent. Unsupported or unsafe output yields
a typed fallback, not raw engine SVG or raw engine error text. Source CSS
keyframes remain in the accepted subset; the engine document disables animations
with host CSS, which is not a proof that every possible SVG animation is absent.

## Queue and cancellation

Requests execute serially, with at most 32 active/queued requests. A source/theme
cache holds at most 64 entries and 8 MiB including source and validated markup.
Queued duplicates can reuse a result; malformed or unsafe deterministic results
are cached, but timeouts, transient errors and cancellation are not. Removing a
queued request does not cancel another message's render.

The 20-second client deadline, cancellation and WebKit failure retire the owned
surface. Request IDs, surface identity and revisions reject late bootstrap,
render and termination callbacks. A following request can create a fresh surface.
The deadline is a soft client bound: public WebKit APIs do not guarantee killing
an uncooperative WebContent process or enforcing a hard CPU/memory ceiling. No
deprecated process-pool setting is presented as a separate-process guarantee.

Focused backend tests cover FIFO, theme/cache isolation, count and byte eviction,
overflow, shutdown, cancellation, stale deadlines/callbacks, output rejection and
real WebKit recovery. Eight diagram families render with the actual public engine
in both themes. These fixtures establish backend behavior, not every supported
grammar or reference geometry. Transcript evidence is separate below.

## Transcript and viewer integration

`OfflineMermaidView` renders by exact source and resolved appearance. While
waiting, it shows a localized progress label with selectable original source.
Failures show that source with a localized warning rather than engine error
HTML. Source changes, appearance changes, cancellation and removal invalidate
the old request. A revision also fences callbacks from an earlier lifetime of
the same source, so an old click or display failure cannot open or close a newer
preview. Closing a preview leaves the current figure available for reopening.

`MermaidSVGWebView` displays only independently validated SVG in a separate
nonpersistent static document; it does not load or run the Mermaid engine. Page
JavaScript, scripts, images, network requests, navigation, downloads, popups and
dialogs are disabled. The only native isolated-world operation waits for fonts
and applies bounded viewport geometry and appearance. A geometry ticket is
checked again inside JavaScript after that wait, preventing a delayed older
transform from replacing a newer one. A ten-second soft display deadline falls
back to source; it is not a hard WebContent process termination guarantee.

The figure fits the real SVG viewBox inside a bounded native viewport. Its
whole-figure and expand-button actions support click and focused Return/Space.
The native viewer uses the same validated vector output and existing pan, zoom,
fit, keyboard and window-lifetime behavior. Resize preserves the chosen scale,
as in the recovered reference; F, 0, double-click or the fit button resets it.
The rendered surface stays viewport-sized even at 8× zoom of a 20,000-point
logical image. Appearance updates change the static canvas background without
reloading the SVG or discarding the chosen transform. No file, tool, account or
integration authority is added by opening a diagram.

If the viewer's display fails, its pan/zoom input overlay is removed and zoom
controls are disabled. The original source remains selectable and scrollable,
instead of leaving an empty interactive diagram surface above that text.

Real `TranscriptMessageView` and `GroupMessageBubble` fixtures cover flowchart,
sequence, state, pie, class, entity relationship, Gantt and mindmap output, plus
unsafe-source fallback in both routes. Unshown native windows verify figure
actions, viewer dimensions, fitted SVG bounds, cancellation, late callbacks,
failure recovery and seven languages in both appearances. Actual WebKit
snapshots are inspected alongside native controls; a host bitmap alone does not
establish that the SVG was drawn. These isolated checks are not a human
VoiceOver, OS full-screen or minimum-macOS acceptance run.

## Remaining boundary

The public engine is connected to the actual transcript and viewer, but the
bounded output gate deliberately does not accept every possible public-engine
output. Eight tested families do not establish the full grammar. Neither the
public archive nor dependency notices establish opaque-byte or pixel-identical
parity. `UI-04`, human/minimum-macOS checks, hard runtime resource containment and
external/release acceptance remain partial. Final test and build evidence is
recorded in [the completion audit](Parity-completion-audit.md).
