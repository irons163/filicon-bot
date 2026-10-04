# Offline KaTeX formula rendering

Filicon renders explicit Markdown math in direct and group transcripts with a
locally bundled KaTeX engine. Matrices, aligned equations, binomials, math
alphabets, roots and annotated braces use the public engine, not the previous
small hand-written TeX parser. Formula source is retained unchanged.

## Reference and provenance

The reference is `grok-bot-0.18-reconstructed` at
`a9f633e09d49a85829b8236331b9e21f7e612634`. Its recovered
`frontend/src/recovered/features/conversation/workspace/math.tsx` uses
`renderToString`, display/inline modes, a tolerant parse-error pass, and escaped
fallback content. Its root `package-lock.json` pins public KaTeX **0.16.45**.

The opaque recovered `katex-DHMw6HUq.js` asset is unavailable in this checkout.
Filicon imports the exact public package version and verifies the archive's
SHA-512 against that lockfile. This is not a claim of byte equivalence with the
original shipped asset, or support for optional KaTeX extensions not imported by
the reference. The package MIT license is included unchanged.

`Sources/FiliconRichContent/Resources/KaTeX` contains the engine, stylesheet,
20 WOFF2 fonts and license. Its manifest records every file's bytes and SHA-256;
the manifest itself is pinned in the loader and packaging verifier. The importer
does not install dependencies or execute package scripts. To reproduce an import
from the already-downloaded, pinned archive:

```sh
ruby scripts/import-katex.rb /explicit/path/katex-0.16.45.tgz
ruby scripts/verify-katex.rb Sources/FiliconRichContent/Resources/KaTeX
FILICON_KATEX_IMPORT_ARCHIVE=/explicit/path/katex-0.16.45.tgz ruby scripts/test-katex.rb
```

Importer tests use a temporary repository fixture, not the actual vendor files.
Without the archive environment variable, the two import-specific tests skip;
resource-verification tests remain available offline.

## Execution and rendering

Only the verified engine is evaluated in JavaScriptCore. TeX is passed as a
function argument, never interpolated as JavaScript. The VM has no host file,
network or application APIs. A serialized context and fresh macro dictionary per
render prevent concurrent messages or global TeX definitions from sharing state.
The tolerant parse-error retry also starts with a fresh dictionary.

The result includes KaTeX layout HTML and accessible MathML. A nonpersistent
WebKit view displays this static document with page JavaScript disabled. Its CSP
blocks external connections, images, frames and active content; the navigation
delegate rejects external navigation and downloads. Fonts are verified bundle
bytes embedded as data URLs. Native-owned height measurement runs in an isolated
content world after fonts are ready. Light/dark appearance follows the host.
This does not provide browser tools to an agent.

Native measurements resize normal formulas rather than clipping them to the old
96-point maximum. The viewport is capped at 1,024 points; taller or wider content
can scroll. Source changes invalidate old measurements, and dismantling removes
callbacks, navigation state and document references.

## Safety and resource bounds

The engine uses `trust: false`; any attempted trust-requiring command causes an
exact source fallback, including HTML attributes, external images and hyperlinks.
Parse errors are escaped by KaTeX's tolerant pass. Invalid or missing assets,
engine errors and rejected input preserve literal source rather than executing
user HTML or trapping on SwiftPM's generated missing-bundle accessor.

Each input is limited to 16,384 UTF-8 bytes and 128 levels of unescaped brace
nesting. Control characters other than tab/newline are rejected. Expansion is
capped at 1,000 and user-specified physical sizes at 20 em. Output is limited to
1 MiB, and successful/failed render cache entries to 128 and 8 MiB combined. These
are deliberate resource limits, not unbounded reference behavior or a hard
wall-clock execution deadline. No private JavaScriptCore timeout API is used.

These choices follow KaTeX's primary [options](https://katex.org/docs/options.html)
and [security](https://katex.org/docs/security) documentation. The
[API documentation](https://katex.org/docs/api) also describes isolating macro
objects across trust boundaries.

## Verification and remaining work

`KaTeXEngineTests` exercises the actual pinned engine, tolerant errors, trust
rejection, macro isolation, concurrent calls and resource/cache bounds.
`KaTeXAssetTests` rejects missing, modified and symlinked resources, including a
whole missing bundle. `KaTeXRenderingTests` reaches both real transcript routes,
checks multiline auto-height and tall-content scrolling, validates seven UI
languages in light/dark appearance, and verifies that ordinary page scripts do
not execute. Snapshot windows are not displayed and do not use real chat data.

Xcode and standalone packaging ship the same SwiftPM resource bundle.
`verify-package.sh` rejects missing or changed math resources in addition to its
existing executable, entitlement and deep-signature checks. Final test/build
results are recorded in [the completion audit](Parity-completion-audit.md).

`UI-04` remains partial. Inline formulas still occupy separate transcript layout
segments rather than flowing on the same prose baseline; table inline math is
not yet connected. The full strict Mermaid runtime and precise diagram geometry,
human VoiceOver/focus checks, minimum macOS runtime and external/release gates
remain independent requirements. MathML presence is not proof of human
accessibility acceptance. No live model, account, App launch or publication is
required for the offline fixture checks above.
