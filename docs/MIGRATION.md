# Native macOS migration（current implementation）

Filicon is a macOS 14 Swift package. The native Swift targets and their
composition in `FiliconApp` are authoritative; the stable parity IDs and
status map live in [PARITY.md](PARITY.md). This document records the current
dependency and security boundaries, not a future migration plan.

## Dependency direction

```text
SwiftUI / AppKit surfaces
        |
     AppModel
        |
  App services and coordinators
   |       |        |        |
Domain  Provider  Persistence  Settings/Security
        kit       + recovery
   |       |        |        |
Tools/MCP  HTTP + CLI  SQLite/FTS  Keychain/WebAuthn
Agents, channels, automations, computer, attachments, voice and updater
```

`AppModel` owns presentation state and composition. Provider wire data is
normalized by `FiliconProviderKit` before it reaches the UI. Persistence,
attachments, automation runs, and update staging have actor-owned services;
credentials are represented by references and resolved only at the boundary
that needs them.

## Current native boundaries

| Area | Current target/boundary |
| --- | --- |
| Conversations and transcript | `FiliconDomain`, `FiliconAppServices`, `FiliconPersistence`, `TranscriptEventHub` |
| Providers | `FiliconProviderKit` HTTP adapters plus `CodexCLIProvider` and `ClaudeCodeCLIProvider`, each using the official CLI auth session when selected |
| Tool loop and MCP | `ToolLoop`, `FiliconMCP` stdio/HTTPS transports, OAuth, catalog and approval dispatch |
| Local execution | `FiliconLocalTools` with `FiliconLocalToolHelper` and `FiliconLocalToolXPCService`; policy remains in the app |
| Attachments and voice | content-addressed `AttachmentStore`/`AttachmentLifecycle`; Quick Look/safe spreadsheet preview; native recorder/transcriber |
| Agents and rooms | `FiliconAgents`, `FiliconChannels`, `FiliconSharedRooms`; scoped subagents, cloud runs, connectors, delivery and reactions |
| Automations | `FiliconAutomations` scheduler/ingress plus `AgentWorkflow*` import, codec, runtime and attachment-backed Teach-scope dispatch |
| Computer | `FiliconComputer` local/remote lifecycle, isolation, terminal/file transfer, VNC bridge and Teach recording/masking |
| Account and settings | `FiliconAccount`, `FiliconSettings`, `FiliconSecurityKey`, `FiliconAutoReview`, Keychain-backed state |
| Window, notifications and links | native window state, `SystemNotifications`, in-app notification center, Dock projection and strict deep links |
| Updates and packaging | `FiliconUpdater`, update helper, `scripts/package-app.sh`, release/feed generation and artifact verification |

## Provider contract

All providers emit the same ordered domain vocabulary: response start, text or
reasoning deltas, tool-call start/argument/completion, usage, and terminal
completion. HTTP SSE/NDJSON adapters and the Codex/Claude Code CLI parsers
normalize malformed, truncated, authentication, rate-limit, refusal, transport
and cancellation failures before presentation. Model catalogs carry provider,
default, reasoning and unavailable state without exposing credentials.

## Security invariants

1. Raw provider, account, MCP, channel, shared-room and remote-computer
   credentials are stored in Keychain or an opaque reference, never in
   transcripts, settings JSON, logs or UI state.
2. A conversation stores provider/model identifiers and normalized events, not
   authorization headers or CLI session files.
3. Tool declarations are data. `ToolLoop` validates JSON/schema, keeps a
   stable catalog snapshot, enforces the eight-step ceiling, and persists
   ordered results before the next provider request.
4. Local mutation tools run through the XPC helper. Approval receipts are
   scoped to action/target/call/generation, fail closed, expire, and reject
   replay; child processes are bounded and terminated as a group.
5. MCP, channel, shared-room and remote-computer transports require validated
   HTTPS/origin or an explicitly configured local transport, bounded payloads,
   credential-safe redirects, and cancellation propagation.
6. Attachments are content-addressed and re-verified before preview/export;
   previews never execute scripts, macros or arbitrary active content.
7. Workflow, automation, agent and Teach dispatch paths use explicit scopes,
   authenticated ingress and durable run history. A model or event payload
   cannot grant authority by itself.
8. Update artifacts require HTTPS, digest verification, and Ed25519 signature
   verification when a trusted production key is configured. Backend minimum
   version signals persist before required-update checks run.

## Data and recovery

SQLite owns conversation/message/search and attachment references. Settings,
agent/workflow/automation state, and bounded run histories use atomic writes
with schema normalization. Startup resolves the canonical data root, fences
stale account/workspace generations, quarantines malformed state, rebuilds
recoverable indexes, and surfaces retry/recovery state in the UI. Pending
turns, automation runs, workflow runs, channel deliveries, and Teach captures
are never silently replayed after a crash.

## Release and verification state

`UPD-01`, `UPD-02`, and `UPD-03` cover the current package, updater state machine,
default feed resolution, runtime/idle signals, required-update UI, backend
requirement signal, staging, installation and rollback checks. `UPD-03` is
complete: the `v0.18.0` GitHub Release contains the notarized/stapled ZIP and
DMG, signed update feed, and SHA-256 manifest. App/DMG notarization, Gatekeeper
and stapler validation, clean-install checks, remote checksums, and public feed
signature verification all passed. `UPD-04` is `NA` because Electron/ASAR/
preload/Windows runtime wiring is not a macOS product behavior.

Final verifier evidence: 553 tests (420 Swift Testing and 133 XCTest) pass;
WAE and release build pass; release `0.18.0-184` passes notarization, stapling,
Gatekeeper, clean-install, launch smoke, remote checksum, and feed-signature
verification. These are historical release checks, not proof of full current
source parity. The September 18 reconstructed-source audit found group
collaboration gaps; see AGENT-01/AGENT-02/AGENT-04 in PARITY.md and the itemized
Agent-collaboration-parity.md audit. Manual peer sends now wake real inference,
scoped peer context survives restarts, and text-only SendMessage publishes through
the host. An App-injected cross-origin per-agent FIFO scheduler now covers group
turns, mailbox wakes, subagent tasks, automations, workflows and channel replies,
including owner-specific cancellation and host-tool cleanup joining. Generic
direct chats without an agent profile remain conversation-scoped. Unified
personal memory, priority preemption, cross-process/restart scheduling and full
messaging variants remain incomplete. Scoped CreateAgent/UpdateAgent now run in
group and mailbox turns with mandatory exact-field approval, a four-change cap,
stop/account revocation and replay protection. Creation inherits the requester's
model but no private context, membership or permissions. Updates change only
name/public summary, not private persona. Own-profile
`update_state(target:"profile", action:"set")` now uses the same approval and
revocation path, a host-fixed identity and the shared four-change cap. An explicit
empty description clears only the public summary. Subsequent group turns reload
the profile without expanding the original participants. Other update_state
targets and full private persona/memory parity remain incomplete.
SendToAgent now supports reviewed text posts into other local groups the sender
belongs to, followed by bounded member turns in that shared room. This is not a
set of private DMs. Audience changes invalidate approval; busy rooms reject sends;
the current room uses SendMessage. Each request permits two distinct group posts
within the six-delegation cap. Stop retains durable posts but cancels unfinished
work without replaying it at restart. Target-room tools keep source-scope approval
gates, and source-private history is not forwarded.
See the collaboration audit for current validation limits.
