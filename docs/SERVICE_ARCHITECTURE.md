# Filicon native service architecture

## Purpose and provenance boundary

This document is the implementation contract for the current service layer:
tools, MCP, agents, groups/channels, automations, computer integration and
attachments. The Swift targets under `Sources/` are authoritative; the document
describes their native contracts rather than a source-level port.

All `source/...` references below are relative to
`grok-bot-0.18-reconstructed`. The native constraints already declared by
Filicon remain authoritative: provider events normalize before reaching the
UI, credentials stay in Keychain, local mutation tools require approval plus
process isolation, and a model turn has an eight-step tool ceiling
(`filicon-bot/docs/MIGRATION.md:58-80,98-110`).

External integrations use public provider/MCP contracts, macOS frameworks,
user-authored configuration and Filicon-owned schemas. Credentials, private
service protocols and generated upstream artifacts never cross the native
service boundaries. Remote computer, VNC, cloud-agent and shared-room support
use the explicit HTTPS, scoped transport and isolation contracts implemented by
`FiliconComputer`, `FiliconAgents` and `FiliconSharedRooms`.

## Dependency and trust graph

```text
SwiftUI views
  -> AppModel facades (MainActor, presentation state only)
      -> AgentService / GroupService / AutomationService actors
      -> ToolLoop actor
          -> ProviderKit adapters (untrusted provider wire data)
          -> ToolCatalog actor
              -> MCPService actor -> stdio child or HTTPS transport
              -> LocalToolBroker actor -> XPC helper (untrusted local process)
      -> AttachmentLifecycle actor -> AttachmentStore actor
          -> AttachmentReferenceRepository -> SQLite + blob files
      -> CredentialStore actor -> Keychain

AutomationScheduler -> RunScheduler -> AgentService -> ToolLoop
ChannelConnector ----^                 |
AgentMessenger ------^                 `-> durable transcript/run history
```

Trust rules:

1. SwiftUI never receives secrets, raw authorization headers, child-process
   handles, provider wire frames, or arbitrary MCP objects.
2. Every external payload is bounded and schema-validated at its adapter.
3. A tool declaration is data; only a registered executor can make it active.
4. A model-generated tool call never constitutes permission.
5. Cancellation flows from conversation/run to provider request, MCP request,
   child process, XPC operation, and any subagent spawned by that run.
6. Persist state before acknowledging externally visible mutations or wakes.

## Shared domain contracts

The current `FiliconDomain/ToolModels.swift` target owns these transport-neutral
concepts:

```swift
struct ToolName: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }
struct ToolCallID: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }

struct NormalizedToolCall: Codable, Hashable, Sendable {
    var id: ToolCallID
    var name: ToolName
    var argumentsJSON: Data       // complete UTF-8 JSON object only
}

enum ToolResultContent: Codable, Sendable {
    case text(String)
    case resource(uri: String, mimeType: String?)
}

struct NormalizedToolResult: Codable, Sendable {
    var callID: ToolCallID
    var content: [ToolResultContent]
    var isError: Bool
}

enum RunLane: Int, Codable, Sendable { case user = 0, agent = 1, background = 2 }
enum RunStatus: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled }
```

`InferenceEvent` carries ordered tool-call start/arguments-delta/completion
events. Provider adapters own wire correlation (OpenAI item/call IDs,
Anthropic content block indices, Gemini function-call parts); downstream code
only sees `NormalizedToolCall`. The native implementation preserves tool
identity across partial and completed events
(`source/host/runner/tool-call-identity.ts:1-2`) and models streaming tool-call
deltas (`source/packages/agent/tool-stream-executor.ts:64-65`).

Persist these records with schema versions and stable UUIDs. Unknown enum cases
must decode to an explicit `unknown` representation or fail migration; never
silently reinterpret a mutation as read-only.

## Provider tool-call normalization and bounded loop

### Service shape

```swift
protocol ToolExecutor: Sendable {
    var descriptor: ToolDescriptor { get }
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws
      -> NormalizedToolResult
}

actor ToolCatalog {
    func snapshot(for context: ToolContext) async -> ToolCatalogSnapshot
    func executor(named: ToolName, snapshot: ToolCatalogSnapshot) -> (any ToolExecutor)?
}

actor ToolLoop {
    static let maximumSteps = 8
    func run(_ request: InferenceRequest, context: ToolContext)
      -> AsyncThrowingStream<InferenceEvent, Error>
}
```

A step is one provider response followed by execution of all tool calls emitted
in that response. Calls within one step may run concurrently only when every
descriptor is explicitly parallel-safe and their approval scopes do not
overlap. Results are appended in original call order. At step 8, any further
tool request terminates with `toolStepLimit`, cancels outstanding work, and is
recorded visibly; the model is not given a ninth chance.

Invariants:

- Catalog snapshot and provider/model route are immutable for the whole loop.
- Tool call IDs are unique within a run; duplicate completion, result without a
  call, malformed JSON, unknown tool, or schema mismatch is a typed error.
- Persist assistant tool-call message and every result transactionally before
  requesting the next provider step.
- Provider finish reasons (`tool_use`, `tool_calls`, Gemini function calls) map
  to the same state machine. Text plus tool calls in one response is retained.
- Cancellation is terminal and idempotent. No detached executor survives it.
- Tool output is untrusted content, never system instructions. Large text is
  spilled to a blob/file reference; the reconstruction uses a 40 KB inline
  threshold and explicit truncation fallback
  (`source/packages/agent-exec/agent-tools-file.ts:12`,
  `source/packages/agent/tools/mcp/mcp-output-spill.ts:24-119`).

UI flow: render streaming call name and bounded arguments preview; show
approval cards when needed; render running/succeeded/failed/cancelled status;
offer reveal/copy for results, never auto-open URLs or files.

Acceptance tests:

- Identical OpenAI, Anthropic, and Gemini fixtures produce byte-equivalent
  normalized calls and ordered results.
- Split UTF-8/JSON arguments, two parallel calls, duplicate IDs, unknown tools,
  malformed schema, cancellation at each phase, and an attempted ninth step.
- Crash after call persistence but before result persistence resumes as
  interrupted, not by executing the mutation twice.

## MCP

### Configuration and transports

The source accepts stdio (`command`, `args`, `env`, `cwd`) and remote URL
servers with headers and HTTP/SSE variants
(`source/packages/cursor-plugins/types.ts:17-31`,
`source/shared/node/mcp/mcp-display-runtime.ts:2-6`). It resolves `.mcp.json`
or `mcp.json`, supports a root `mcpServers` object, tracks source paths, and
expands variables (`source/packages/cursor-plugins/mcp-parser.ts:8-16,42-105`).

Filicon-owned configuration:

```swift
struct MCPServerConfig: Codable, Sendable, Identifiable {
    var id: UUID
    var identifier: String       // normalized, unique, prompt-safe
    var displayName: String
    var transport: MCPTransportConfig
    var account: String          // default or named account
    var enabledTools: Set<String>?
    var disabledTools: Set<String>
    var customInstructions: String
    var enabled: Bool
}

enum MCPTransportConfig: Codable, Sendable {
    case stdio(executable: String, arguments: [String], environmentRefs: [String: CredentialRef], cwdBookmark: Data?)
    case streamableHTTP(url: URL, headerRefs: [String: CredentialRef])
    case legacySSE(url: URL, headerRefs: [String: CredentialRef])
}
```

Raw secrets are never serialized. Environment and header values are Keychain
references. Remote transports require HTTPS except explicit loopback; redirects
may not downgrade scheme or forward authorization cross-origin. Stdio requires
an absolute executable resolved outside the app bundle, an approval at install
time, a sanitized environment, bounded stdout/stderr, process-group
cancellation, and no shell interpolation.

```swift
protocol MCPTransport: Sendable {
    func connect() async throws -> MCPConnection
}
protocol MCPConnection: Sendable {
    func initialize() async throws -> MCPCapabilities
    func listTools(cursor: String?) async throws -> MCPToolPage
    func callTool(name: String, arguments: Data, requestID: UUID) async throws -> MCPResult
    func listResources(cursor: String?) async throws -> MCPResourcePage
    func readResource(_ uri: String) async throws -> MCPResult
    func cancel(requestID: UUID) async
    func close() async
}
actor MCPService { /* config, connection leases, discovery, execution, health */ }
```

### Catalog, execution, and status

Server state is `disabled | connecting | connected | needsAuth | error`, with a
sanitized bounded detail. Catalog entries include server/account identity,
tool name, description, JSON Schema, annotations, and a catalog revision. The
source exposes the same server status/tool count/custom-instruction shape
(`source/host/extensions/mcp/mcp-service.ts:30-40`) and separates discovery
from execution (`.../mcp-service.ts:151-161`). Tool descriptions are untrusted:
strip control/markup, cap prompt size, and never allow a server to claim a
built-in namespace. Discovery is paginated, cancellable, cached by config and
connection revision, and invalidated on reconnect/config change.

Execution validates arguments against the catalog snapshot, applies read-only
and user approval policy, sets a timeout, and normalizes MCP text/image/resource
content. Tool/server-not-found, needs-auth, rejection, permission, transport,
timeout, malformed result, and server-declared `isError` remain distinct. The
source makes these distinctions in
`source/packages/agent/tools/mcp/mcp-result-boundary.ts:18-180`.

### OAuth

```swift
actor MCPOAuthCoordinator {
    func begin(serverID: UUID, account: String) async throws -> OAuthSession
    func receiveCallback(_ url: URL) async
    func cancel(_ sessionID: UUID) async
}
```

Use Authorization Code + PKCE where supported, a cryptographically random
single-use state, ASWebAuthenticationSession when possible, and a loopback
listener bound only to `127.0.0.1`/`::1` when required. Verify exact state,
redirect origin/path, expiry, and one completion; store refresh/access tokens in
Keychain and only authentication status in SQLite. The source correlates state,
accepts loopback hosts, times out completion, and defaults to a localhost
callback (`source/shared/node/mcp/mcp-oauth-loopback.ts:38-82,160-230`). Do not
reuse its fixed port or backend completion endpoint.

UI flow: Settings > MCP lists transport/account/status/tool count; Add validates
without saving secrets to config; Connect opens browser and shows cancellable
progress; tool toggles and custom instructions are per server/account; Remove
terminates processes, revokes locally stored tokens, and leaves audit history.

Acceptance tests include fake stdio and local HTTP MCP servers, initialize
negotiation, pagination, reconnect, stderr flood, timeout/cancel/process reap,
OAuth wrong/replayed/expired state, redirect downgrade, schema rejection,
disabled tool, large output spill, and a secret scan of DB/logs/UI snapshots.

## Local file and shell execution

The source policy has `always | ask | never`, default `ask`, an optional admin
ceiling, and actions run-command/send-input/read-file/list-directory/write-file
(`source/shared/local-tool-permission.ts:1-25`). Requests are scoped by agent,
tool-call, action, target and direction epoch; one-time approval covers only the
exact action/target or an owned attached resource, expires after ten minutes,
and is retired on a new user turn
(`source/shared/local-tool-permission-machinery.ts:3-57`,
`source/host/extensions/local-tool-permission/local-tool-permission-controller.ts:15-31,45-80`).

Current native boundary:

```swift
protocol LocalToolBroker: Sendable {
    func request(_ operation: LocalOperation, scope: ApprovalScope) async throws -> LocalOperationResult
    func cancel(scope: ApprovalScope) async
}
actor ApprovalController { /* exact receipts, TTL, epoch, denial memory */ }
// XPC target only:
protocol LocalToolXPC { func perform(signedEnvelope: Data, reply: @escaping (Data) -> Void) }
```

The app process owns policy and UI; a hardened XPC helper owns file descriptors
and child processes. Use security-scoped bookmarks for user-selected roots,
canonicalize with `realpath`, reject traversal/symlink escape and special
files, use argv arrays rather than `/bin/sh -c`, start a process group, stream
bounded output, and terminate the whole group on cancel/timeout/app exit. Each
XPC envelope includes nonce, agent/run/tool-call IDs, action, canonical target,
expiry, and an HMAC/session binding; replay is rejected. The helper cannot read
Keychain provider/MCP secrets and has no network entitlement.

Approval UI shows exact command argv or canonical file/root, write intent,
agent, and choices Allow Once / Deny / Always for this narrowly defined class.
Changing the standing setting never retroactively approves an abandoned call.

Acceptance: symlink race and traversal fixtures, shell metacharacters passed as
literal argv, 10 MB output bound, stdin after process exit, cancel kills
grandchild, stale/replayed receipt, new-turn expiry, Never/admin ceiling, XPC
crash/reconnect, and proof the main app never directly spawns mutation tools.

## Agents, subagents, and messaging

### Persistent agents

```swift
struct AgentProfile: Codable, Sendable, Identifiable {
    var id: UUID; var name: String; var summary: String; var instructions: String
    var providerID: ProviderID; var modelID: ModelID; var avatar: AvatarSpec?
    var createdAt: Date; var archivedAt: Date?
}
actor AgentService { /* profile CRUD, transcript ownership, run scheduling */ }
```

Profiles are versioned and atomically persisted. The source profile separates
name, description/title and avatar fields
(`source/host/agents/agent-profile.ts:3-47`), caps 50 agents and six group
members (`source/shared/agents/agents.ts:45-59`), and cloning copies profile,
settings, automations, and history while rewriting identity
(`source/host/agents/agent-clone.ts:7-24`). Native clone must create new IDs,
exclude credentials and pending/running work, and default to no chat history
unless the user explicitly opts in.

### Ephemeral subagents

```swift
actor SubagentService {
    func launch(_ spec: SubagentSpec, parent: RunID) async throws -> SubagentID
    func status(_ id: SubagentID) async -> SubagentStatus
    func steer(_ id: SubagentID, message: String) async throws
    func cancel(_ id: SubagentID) async
}
```

Persist lineage (`parentRunID`, parent tool-call ID), status, title, start/end,
usage and final result. Background completion creates a durable wake for the
parent; cancellation disarms it. Steer interrupts the current inference then
continues with context, while Stop is terminal. These match
`source/host/runner/subagent-runtime.ts:3-35,64-123,137-260` and the inspect /
steer / stop tool surface in
`source/host/runner/tools/sand-subagent-management-tools.ts:5-48,74-180`.
Apply per-parent and global concurrency caps, depth cap, budget inheritance,
cycle prevention, and cancellation propagation. No subagent gains permissions,
roots, connectors, or credentials absent from the parent scope.

### Agent-to-agent messages

Messages are durable, asynchronous, at-most-once delivered to a recipient run
queue, and idempotent by message UUID. Maximum text is 8,000 characters; no
self-send. Normal messages use the agent lane ahead of background work;
priority may interrupt non-user work but never a user turn. Images are blob
references, not arbitrary readable paths. The source establishes these
semantics in `source/host/agents/agent-messaging.ts:3-18,30-52` and
`source/host/extensions/transcript/agent-to-agent-messaging.ts:14-51,63-132`.

UI: agent sidebar/profile editor; clone/archive confirmation; child-task panel
with elapsed time/activity/status and Steer/Stop; visible inbound/outbound peer
messages with sender identity and priority marker. Never make agent speech look
like user speech.

Acceptance: profile migration/clone identity, 50-agent cap, parent-child cycle
and depth rejection, concurrent cap, restart recovery of completion wake,
cancel/steer race, self-send, duplicate message id, priority ordering without
interrupting user lane, attachment ownership, and deletion/archive cleanup.

## Groups, channels, and reactions

### Local groups

```swift
struct AgentGroup: Codable, Sendable, Identifiable {
    var id: UUID; var name: String; var summary: String; var memberIDs: [UUID]
}
actor GroupService { func post(_ message: RoomMessage, to: UUID) async throws }
```

Groups contain individual local agents only, never nested groups, with unique
members and a six-member cap. Mention resolution supports `@everyone`, `@all`,
full/compact/first-name handles. A bounded round robin rotates the first
speaker, stops on all-pass, and cannot exceed three rounds, ten member messages,
or two messages per member turn. These exact behavioral references are
`source/host/groups/group-chat.ts:1-15` and
`source/host/extensions/transcript/group-chat-orchestrator.ts:24-102`.
Every member receives only room history plus its profile; private 1:1 context is
never injected. Only an explicit room-send operation publishes member output.

### External channels

Define a plugin-neutral adapter rather than embedding Slack/Discord APIs:

```swift
protocol ChannelConnector: Sendable {
    var descriptor: ChannelDescriptor { get }
    func inbound() -> AsyncThrowingStream<ChannelEnvelope, Error>
    func send(_ message: ChannelOutbound, to: ChannelAddress, idempotencyKey: UUID) async throws
}
actor ChannelService { /* connections, dedupe cursor, retry/dead-letter, activity */ }
```

Connection metadata is non-secret; tokens are Keychain refs. Inbound envelopes
carry platform, channel/thread, sender, timestamp, external event ID and blob
attachments. Deduplicate before transcript append, preserve source attribution,
and queue a failure wake when outbound delivery fails. The source stores channel
connection metadata separately (`source/host/extensions/session/channel-store.ts:6-35`)
and turns inbound/failure events into background wakes
(`source/host/extensions/transcript/background-wakes.ts:78-218`).

### Reactions

A reaction targets a stable message ID/address, contains one normalized emoji,
is attributed to actor, and toggles the same actor/message/emoji tuple. Only
messages visible in that room/channel may be targeted. The source validates a
message address and uses toggle semantics
(`source/host/runner/tools/sand-reaction-tool.ts:7-56`).

UI: room transcript with speaker chips and mention completion; bounded run
indicator/Stop; channel connection and thread badge; reaction picker/pills with
accessible labels. Initial release explicitly labels groups text-only if image
fanout is not implemented—never silently discard attachments.

Acceptance: nested/duplicate/over-six membership, mention boundaries, rotation
fairness, pass/all-pass and all caps, epoch cancellation, private-context
isolation, inbound dedupe/restart cursor, outbound retry/idempotency, connector
auth expiry, reaction toggle/authorization, and group attachment rejection.

## Automations, schedules, wakes, history, and spend guard

### Schema and scheduler

```swift
enum AutomationTrigger: Codable, Sendable {
    case cron(expression: String, timeZone: String?)
    case event(connectorID: UUID, kind: String, filters: JSONValue)
    case anyOf([AutomationTrigger])
}
struct Automation: Codable, Sendable, Identifiable {
    var id: UUID; var agentID: UUID; var name: String; var prompt: String
    var trigger: AutomationTrigger; var enabled: Bool
    var createdAt: Date; var lastRunAt: Date?; var revision: Int64
}
struct AutomationRun: Codable, Sendable, Identifiable {
    var id: UUID; var automationID: UUID; var trigger: TriggerOrigin
    var startedAt: Date; var finishedAt: Date?; var status: RunStatus
    var detail: String?; var coalescedEventIDs: [String]
}
actor AutomationScheduler { /* next-fire heap, event matching, durable claims */ }
actor RunScheduler { /* per-agent user > agent > background lanes */ }
```

Support five-field cron, aliases (`@hourly` etc.), `@every`, and `CRON_TZ` with
IANA zones. Cron day-of-month/day-of-week uses standard OR behavior when both
are restricted. Search is bounded to 366 days. The reference implementation is
`source/shared/automation-schedule.ts:2-18`. Store original normalized schedule,
timezone, and computed next instant; compute wall clock with Calendar/TimeZone,
including DST skip/repeat policy documented as “next valid instant, fire once.”

Event triggers are typed connector subscriptions. Preserve the source concepts
of Slack message/mention/keyword/reaction, GitHub events, Teams message, Linear,
Sentry and PagerDuty, plus an any-of group capped at eight listeners
(`source/shared/automations.ts:1-8`). `FiliconAutomations` and the workflow
integration implement these adapters; unknown trigger kinds remain persisted
and visibly disabled—not deleted or treated as cron.

The run scheduler allows one active run per agent and prioritizes user, then
agent, then background lanes; user work may interrupt wedged background work
after a bounded grace period. This is grounded in
`source/host/extensions/transcript/run-scheduler.ts:3-42,48-104,151-227`.
Automation firing uses a transactional durable claim keyed by
automation/revision/scheduled-instant or external event ID. Coalesce event
bursts up to 25 payloads; external payload is quoted as untrusted data, never
instructions. Manual Run Now uses the same path and audit record.

### Durable wakes and history

On completion, insert transcript/run history and a pending wake in one SQLite
transaction; clear the wake only after the parent/UI acknowledges it. Pending
wakes are keyed by agent, kind, and work ID and written atomically in the source
(`source/host/extensions/transcript/sand-pending-wake-store.ts:9-57,91-155`).
Run history keeps newest 20, with status running/ok/error, trigger origin,
timestamps and bounded detail; definitions cap at 50 per agent
(`source/host/automations/automation.ts:8-13,84-89`,
`source/host/automations/automation-store.ts:52-79`). On startup, mark orphaned
`running` entries interrupted and rearm valid pending wakes; never rerun a
mutation merely because the app crashed.

### Spend guard

Persist last viewed time, unread count, fires since viewed, nudge time, snooze,
opt-out, guard-paused automation IDs and card ID. Reference thresholds are:
away three days, 15 unread or 20 fires to nudge, pause after another three days,
and snooze 30 days
(`source/host/extensions/transcript/sand-automation-spend-guard.ts:2-10,30-57`).
The app—not the model—applies Keep/Pause all/Never ask/Resume/Stay paused. Resume
only routines paused by the guard; do not override routines the user had
already disabled. Show estimated and actual token/cost usage per run when the
provider supplies pricing; thresholds remain effective without price data.

UI: Automation list with enabled state, human schedule, timezone, next/last
run, last 20 runs, Run Now/Edit/Pause/Delete; creation preview and confirmation
for background side effects; event connector health; spend-guard card and bulk
pause banner.

Acceptance: cron field/alias/timezone/DST corpus, 366-day bound, restart before
and after claim, duplicate event IDs, burst coalescing cap, user/agent/background
priority, cancellation, orphan recovery, retained 20-history ordering, unknown
trigger round-trip, 50 limit, spend thresholds and every answer transition,
guard-resume ownership, and no silent run while credentials are unavailable.

## Attachments and blob store

```swift
struct BlobID: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String } // lowercase SHA-256
struct Attachment: Codable, Sendable, Identifiable {
    var id: UUID; var blobID: BlobID; var originalName: String
    var declaredMIME: String?; var detectedMIME: String
    var byteCount: Int64; var owner: AttachmentOwner; var createdAt: Date
}
protocol BlobStore: Sendable {
    func put<S: AsyncSequence>(_ bytes: S, expectedSize: Int64?) async throws -> BlobID where S.Element == UInt8
    func open(_ id: BlobID, range: Range<Int64>?) async throws -> FileHandle
    func retain(_ id: BlobID, owner: AttachmentOwner) async throws
    func release(_ id: BlobID, owner: AttachmentOwner) async throws
}
actor AttachmentLifecycle { /* import, metadata, reference commit, safe preview/export */ }
```

Stream import to a same-volume temporary file while hashing; enforce limits
before and during copy, fsync, then atomically rename to
`Application Support/Filicon/blobs/sha256/aa/<hash>`. SQLite owns metadata and
reference counts; original names are display metadata only. Detect MIME from
bytes, sanitize names, reject device/socket/FIFO, and never follow symlinks
outside a granted root. Reads require an owner reference and bounded range.
Quarantine unsupported active content; previews never execute scripts/macros.

The source uses content-addressed SHA-256 filenames, size limits, 8 MB chunk
reads and 64 KB text previews
(`source/host/extensions/attachments/attachments-service.ts:22-35,47-51,187-217`),
and its conversation blob DB verifies SHA-256 roots and performs reachability GC
transactionally (`source/host/agent-isolation/conversation-blob-store.ts:11-18`).
Native GC marks from messages, tool results, pending/running work, agent
messages/groups and automation history; it retains recent uncommitted writes,
then sweeps in a transaction. Corruption quarantines metadata/database before
rebuild. Secrets and authorization-bearing downloads are never persisted as
link previews.

UI: import progress/cancel, file card with name/type/size, Quick Look only for
safe local blobs, explicit Open/Export, missing/corrupt badge, and storage usage
management. Link previews use HTTPS, DNS/IP rebinding protection, redirect and
byte caps, and never fetch authentication destinations automatically.

Acceptance: same-content dedupe, hash mismatch, extension/MIME mismatch,
mid-stream size overflow, cancel/temp cleanup, symlink/path traversal, range
bounds, reference retention across messages/tools/agents/automations, crash
between rename/DB commit, mark/sweep with pending writes, corrupt DB rebuild,
and active-content preview denial.

## Current module ownership

The implementation is split into these concrete Swift targets and app
facades; each target owns its contracts, persistence and error normalization:

1. `FiliconDomain` owns normalized messages, inference events, tool calls and
   permission/value types.
2. `FiliconProviderKit` owns HTTP and official Codex/Claude Code CLI provider
   sessions, wire parsing, catalog and typed provider errors.
3. `FiliconAppServices` and `FiliconPersistence` own turn coordination,
   transcript events, SQLite/FTS, pagination, recovery, attachments and search.
4. `FiliconMCP` and `FiliconLocalTools` own MCP transport/catalog/OAuth and the
   approval-gated local helper/XPC boundary.
5. `FiliconAgents`, `FiliconChannels` and `FiliconSharedRooms` own profiles,
   groups, subagents, cloud runs, messaging, connectors, rooms and reactions.
6. `FiliconAutomations` owns schedules, ingress, event matching, run history,
   wakes, spend guard and the scheduler; `AgentWorkflow*` owns workflow/Teach
   import, validation, runtime and attachment-backed scoped dispatch.
7. `FiliconComputer` owns local/remote lifecycle, isolation, terminal/files,
   VNC trust/takeover and Teach capture/masking; `FiliconAccount`, settings,
   security-key, auto-review, notifications and updater own their app-facing
   boundaries.
8. `FiliconApp` composes the targets through `AppModel`; it owns navigation,
   presentation, consent surfaces, deep links, launch/recovery wiring and
   update-required handling.

Completion evidence is tracked in `docs/PARITY.md`. Final verifier evidence is
553 tests (420 Swift Testing and 133 XCTest) passing, WAE passing, the release
build passing, and local release `0.18.0-180` passing verification and launch
smoke. The production artifact prerequisite gap remains limited to `UPD-03`.
