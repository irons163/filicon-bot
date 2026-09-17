# Filicon

Filicon is a native, macOS-only SwiftUI port of the product-observable behavior
in the Grok Bot 0.18 reconstruction. Electron, Node.js, preload IPC, Windows
installation code, and Linux container names are replaced with native macOS
equivalents instead of being carried into the new application.

The app uses one streaming contract and dynamic model catalogs for mainstream
AI services:

- OpenAI and OpenAI-compatible services, including OpenRouter-style endpoints
- Anthropic
- Google Gemini
- Ollama on the local Mac

Cloud API keys are stored in macOS Keychain. Ollama does not require a key.
Filicon does not read credentials belonging to Codex, Claude Code, Cursor, or
other applications.

The native workspace includes rich conversations, attachment and voice input,
search and durable transcript replicas, local tools, MCP accounts and approval
policy, agents/groups/cloud runs, channels, automations and importable
workflows, Shared Rooms, plugins and private skills, remote-computer controls,
isolated VNC viewing, Teach capture, account/WebAuthn flows, notifications,
deep links, recovery, storage quotas, and signed update handling.

## Requirements

- macOS 14 or newer
- Xcode 26 or a compatible Swift 6 toolchain

## Build and test

```sh
swift build
swift test
swift run Filicon
```

Create a standalone ad-hoc-signed application bundle with:

```sh
./scripts/package-app.sh
open dist/Filicon.app
```

The Swift package is the source of truth. No Node.js or Electron runtime is
required.

For a Developer ID, notarized, stapled ZIP/DMG and signed update feed, follow
[the production release procedure](docs/RELEASING.md). The production script
fails before creating artifacts when required Apple credentials or feed signing
material are unavailable.

## Scope

The migration preserves product behavior rather than source-line or runtime
implementation parity. Windows-only chrome/installers, Electron IPC/preload,
ASAR reconstruction, private authentication owned by other applications, and
upstream telemetry are not ported. Remote-computer lifecycle and VNC behavior
are included through credential-scoped HTTPS and isolated WebKit boundaries;
they do not depend on the source project's Docker or daemon names.

See the [parity matrix](docs/PARITY.md), [migration plan](docs/MIGRATION.md),
and [service architecture](docs/SERVICE_ARCHITECTURE.md) for observable
acceptance boundaries and security invariants.

## Current limitations

Group chat uses the same registered local/MCP tools and approval gates as direct
chat when the selected provider supports tool calling. Execution badges come
from host tool results; an ordinary text reply (including older history) is not
proof that an action ran. Text-only providers cannot use Filicon tools. Gmail
installation/connect cards are not implemented; configure integrations through
MCP Servers or Plugins instead of asking the model to emit an installation card.

In a group, typing `@` opens a filtered member picker (active group members plus
`@everyone`). Click a member or use ↑/↓ and Return/Tab to insert the name; Escape
closes the picker without changing the draft. Return selects while the picker is
open and sends when it is closed. Option–Return inserts a newline. IME composition
keys are left to the input method so choosing Chinese/Japanese/Korean text does
not send a message.

In a group, `@name` addresses an existing member and `@everyone` addresses all
members. Unknown names are rejected before sending, with the draft preserved.
Stopping a group cancels pending tool execution and approvals; cancelled
approvals cannot authorize a later turn.

Live cloud-provider, account, MCP, Shared Room, publishing, remote-computer, and
Apple notarization checks require credentials and services not stored in this
repository. Contract and integration tests therefore use deterministic local
fixtures; live smoke tests remain explicit and opt-in. The notarized/stapled
production `v0.18.0` artifacts and signed feed are publicly available from the
[GitHub Release](https://github.com/irons163/filicon-bot/releases/tag/v0.18.0);
future releases still require the complete procedure in
`docs/RELEASING.md`.
