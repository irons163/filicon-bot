# Localization verification

Supported locales: `en`, `zh-Hant`, `zh-Hans`, `fr`, `es`, `ja`, `ko`.
System selection uses the primary OS language and falls back to English for
unsupported languages. Explicit selection is persisted with AppStorage.

## Automated checks

```sh
python3 scripts/localization_audit.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
CONFIGURATION=debug scripts/package-app.sh
```

The catalog audit runs before packaging. It checks key parity, empty values,
duplicate keys, placeholder parity, unwrapped UI literals, internal link
preservation, and translated text accidentally used in domain comparisons.
It is a heuristic source scan, not proof that every runtime label is translated.

`LocalizationTests` verifies all seven resource bundles, regional OS language
resolution, English fallback, interpolation reordering and preservation of
user-supplied placeholders. Presentation tests use a task-local English scope,
so they do not depend on or overwrite the developer's language preference.

2026-09-17 verification: 134 XCTest tests and 441 Swift Testing tests passed.
Seven-language settings switching was exercised in the packaged macOS app.
Channels and Agents were checked with French main-window text and Traditional
Chinese labels; long tab labels have an adaptive menu fallback.

## Scope and limitations

The catalogs were expanded with offline translation assistance, then selected
UI labels, technical terms, and permission choices were manually corrected.
This is **not** a native-speaker certification of every sentence in six languages.
Further linguistic review is still warranted, particularly for long diagnostics.
External authenticated service flows and every possible populated/error state
have not all been exercised interactively.

User-authored names/messages, provider/model IDs, paths, URLs, protocol identifiers,
and unknown external diagnostics intentionally retain their original content.
macOS-owned menus, file pickers and permission dialogs may follow the OS language.
Changing the UI language must never change persisted identifiers or credentials.
