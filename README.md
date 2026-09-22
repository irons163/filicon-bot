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

Assistant Markdown keeps separate paragraphs, explicit hard line breaks,
headings, list markers/nesting, and quoted blocks readable. Inline emphasis,
code, and reference-style links retain their attributes; ordinary soft-wrapped
lines still follow Markdown's single-paragraph semantics. This only changes
native presentation, not stored message text or link/tool permissions. List and
quote styling is a native approximation, not a pixel-identical web renderer.

Agent collaboration is still partial parity with the unofficial reconstruction;
see [the itemized audit](docs/Agent-collaboration-parity.md). **Agents → Messages →
Attach images…** sends user-selected PNG/JPEG images to a single agent whose
configured model supports image input. Agents may forward only images from the
current incoming peer message, after a new preview approval. `SendMessage` can
publish those same incoming image IDs and a text report to the user after a
separate preview approval. Published images remain visible in the mailbox after
Stop, failure, or restart; this does not message another agent.

The **group composer → Attach images…** also accepts PNG/JPEG (up to four,
5 MB each, 12 MB total), with removable previews. Images are saved in that group
and sent to the configured models of this turn's responding members; `@mentions`
limit the recipients. Every addressed model must support images before the user
message is posted. Invalid, oversized, missing or unsupported images leave the
draft intact. Image-only messages work, and restarted history keeps previews.
Only the current request supplies image bytes to models: later text-only turns
and delegated peer wakes do not reload historical images. An addressed group
member may propose forwarding this request's exact image IDs to one peer via
`SendToAgent`. Every forwarding needs a fresh recipient/message/image preview
approval, even when the recipient is in the same group. The current request and
sender's membership are rechecked after approval. An addressed member may also
publish a text reply with this request's images via `SendMessage`, after a
separate preview approval that identifies the group and its members. The saved
reply survives Stop, later inference failure and restart; it does not add
responders or automatically resend images to other models. Group-target image
broadcasts, arbitrary paths, URLs and generated images remain unsupported.
Imported blobs are not yet automatically cleaned up when removed from a draft.

In **normal group chats**, `SendMessage(type:"widget", widget:...)` can now ask
one choice question with 1–6 options, optional help/option descriptions, and an
optional custom answer. The chat shows the actual option value as well as its
label; select a choice and press **Send answer**, or **Dismiss** without answering.
Publishing the question ends the current tool turn and pauses further group
responses. Answering or dismissing resumes only the asking member, even when the
answer contains `@everyone` or another name. Questions and answers survive restart;
duplicate submissions, another account, archived askers, and changed group
membership cannot reuse a stale question. With `dismissOnMoveOn:true`, a newer
ordinary user message retires the question; the default is false.

A question answer is **not tool approval** and must not contain passwords or
API keys. Writes, image publication and delegation retain their separate gates.
Question widgets are not yet available in mailbox/direct-chat/background peer
wakes.

Normal group agents can quote a prior message with
`SendMessage(text:"…", reply_to:"<shortAddress or UUID from the reply directory>")`.
The host supplies a bounded directory from the latest 40 same-group entries;
empty messages and host status notices cannot be quoted. The chat shows the
original author and a plain-text excerpt, with a button to return to the original.
The relationship survives restart; an unavailable original has a disabled preview.
Quotes do not change recipients, wake additional members, answer choice questions,
or grant tool permissions. Text plus this request's incoming images can include a
quote, but still requires the existing image preview approval; quoted attachments
are never loaded or forwarded. Invalid targets fail without an unquoted fallback.
Group-local short addresses are assigned by the host and persisted with the
message: `t0u` is the first user message, `t0s0` and `t0s1` its first two visible
member replies; `tbs0` is a reply before any user message. Legacy group logs gain
addresses without changing their message UUIDs or content. A bounded prompt never
renumbers messages. Only addresses listed in the current directory or returned
in a successful same-turn publication receipt are accepted;
malformed/ambiguous addresses cannot be guessed or rebound, and the original UUID
route remains available. Replaying one call with its equivalent UUID or short
address does not publish twice. Normal group publications return a host-generated
`messageID` and, when available, `shortAddress` only after the message is saved.
These new targets join the same turn's directory, so a second message can quote
or link to the first without guessing its address. The initial 40-entry directory
can grow by at most two publications; this does not increase the publishing limit.
Failures return no receipt, and cancellation after saving does not republish on
replay. Compatibility transports without a saved identity return no address.
Question receipts still pause the turn; they do not authorize further actions.
Choice questions may also include a quote in a normal group turn:

```json
{"type":"widget","reply_to":"<shortAddress or UUID from the reply directory>","widget":{"prompt":"Which part of this proposal should we review?","options":[{"label":"Layout"},{"label":"Typography"}]}}
```

The quote appears above the question. Answering or dismissing still resumes only
the **asking agent**, not the original message's author or everyone mentioned in
the answer. The quote and pending question survive restart; an invalid quote or
failed save never falls back to an unquoted question. A question cannot include
text or image payloads, even when the current request has images.
Normal group text also supports inline Markdown references, for example
`[the design proposal](sand-msg:t0s0)`, using a listed short address. Clicking the
label scrolls to that earlier message in the same group; it does not create a quote
or thread. The renderer uses the full stored group log (not the bounded prompt)
and the target's UUID, so existing links survive restart and prompt truncation.
Missing, ambiguous, malformed, self/future, or foreign-only targets render as
plain labels. Internal links never launch an external app, fetch previews, load
attachments, route a message, or approve a tool. Code, math, tables and choice
widgets do not activate these links. This is native inline-link navigation, not
the reference app's exact chip styling.
This native routing does not support mailbox/direct-chat/background peer wakes,
or external `channel` destinations.
In the normal group timeline, quoted secondary discussions now fold beneath their
original root message with a reply count. Nested replies share that root and keep
their original quotes. Opening a quote or inline reference expands its thread
before navigation. Pending questions and tools keep their thread open; collapsing
never removes messages or changes permissions. Broken, cyclic, ambiguous or
foreign references remain visible on the main timeline. Expansion is local UI
state, not a persisted message edit. This is native group-thread presentation,
not the reference's automatic composer/session thread stamping or exact chip UI.
Standalone attachments, masked secret requests and vendor-specific cloud-agent
cards also remain outside this `SendMessage` implementation; parity is incomplete.

In group and mailbox turns, an agent can also propose changing **its own avatar**
with `update_state(target:"avatar", action:"set", pet_id:"hoots")`, or restore
the default Codex companion with `action:"clear"` and no `pet_id`. Each change
shows a preview and requires explicit approval, even with auto-review enabled.
Only the nine bundled companions are available to this tool; arbitrary files,
URLs, generated images and changes to another agent's avatar are not supported.
The approved change preserves names, private instructions, models and permissions;
resetting does not delete custom image files. Stop/account changes revoke pending
proposals, and an intervening manual avatar edit invalidates the old proposal.
Avatar, profile, memory, routine and workflow changes share the four-change limit per request.

Group and mailbox agents can propose **changing their own update notifications**:

```json
{"target":"settings","action":"set","notify_on_updates":false}
```

Only those three fields are accepted, and `notify_on_updates` must be a JSON boolean
(not 0/1 or a string). Every request needs explicit before/after approval, even with
an auto-review allow rule. The host selects the owner; models cannot mute peers.
This controls only the agent roster's completion/needs-input system alerts. It does
not mute conversation alerts, hide approval cards, change unread counts/Dock badges,
stop work, hide agents or grant permissions. macOS notification permission is still
required for delivery; enabling does not replay past alerts or remove existing ones.
This is a **local shared agent profile** preference, not an account-scoped setting.

Manual entry: **Agents → Edit → Agent update notifications → Save** (also available
when creating an agent). Existing records without the preference default to on.
New agents and clones default to on unless explicitly configured at creation.
Changes persist across reopening. Settings proposals share the four-change request
budget, Stop/account fences and durable receipts. A dedicated persisted revision
rejects stale proposals and old editors, even after toggling away and back; unrelated
profile changes are preserved. The fence applies within the current service, not
external file edits or multiple app processes. `hidden_from_sidebar` and all other
settings fields remain unsupported and are rejected, including mixed proposals.

Group and mailbox agents can propose **saving or rewriting their own reusable workflow**:

```json
{"target":"workflow","action":"write","name":"Review layout","description":"Use for visual accessibility reviews.","body":"Check keyboard access and text contrast."}
```

This is an `update_state` call, not a scheduled routine. Omit `id` to create;
to rewrite, supply an exact ID from the host's own-agent editable-workflow directory.
All three text fields are required, including the entire replacement body. Limits:
80 characters for name, 1,536 for description, and 8,000 UTF-8 bytes for body.
Outer whitespace is trimmed; name/description are single-line. Body frontmatter
is plain prompt text, never parsed as triggers or permissions.

Only owned, local, manual, single-prompt definitions are eligible. Source-linked
imports, the managed learning workflow, unowned or other agents' definitions,
multi-step/action/scheduled workflows and authority fields are rejected.
An imported copy with no source marker that the user explicitly assigns to an
agent is treated as a local definition, not an immutable external source.
Creation generates a host ID and enables the manual definition; rewriting keeps
its owner, ID, enabled state, trigger and creation time. Neither operation runs
anything, adds a schedule, grants tools or changes existing run history.

Every save needs fresh approval showing the **full before/after definition**,
even when auto-review is enabled. The workflow library is shared by the local
workspace, **not private or account-scoped memory**: other agents and their models,
existing/future workflows and routines may consume the body through references.
Renaming can break name-based references. Known direct references are an advisory
snapshot (count plus at most 100 names/IDs), not the complete or frozen audience.
Do not put private history or credentials into a shared procedure without explicit
authorization. Already running requests keep their captured content.
Stop/account changes revoke pending proposals; any library save through the same
store invalidates pending workflow approval, even if values are later restored.
This revision fence does not coordinate external edits or multiple app processes.
Writes share the four-change budget, atomic persistence and storage quota checks;
the tool's own-agent directory does not reveal other agents' workflow bodies.

To delete an eligible owned definition, propose a separate call:

```json
{"target":"workflow","action":"delete","id":"exact-workflow-id"}
```

Only those three fields are accepted. Deletion requires fresh **destructive approval**
showing the entire current definition and known direct references; write/profile
approvals do not authorize it. There is no undo. Existing run history remains visible
by workflow ID, and runs that already captured the content are not cancelled.
Other workflows and routines (including their schedules), files, sources, connections
and permissions are unchanged. Future references may fail or silently omit the
deleted content. The same owner/revision/Stop/account fences, shared four-change
budget and exact-call receipts apply; deletion does not require new storage quota.
This is bounded native support, not parity with every reference workflow operation.

Group and mailbox agents can propose **pausing, resuming or deleting their own existing
automations** with `update_state(target:"routine", action:"pause"|"resume"|"delete", id:...)`.
The host supplies an own-agent routine directory; each change shows the routine ID,
full task and trigger for fresh approval, even with auto-review enabled. Pause disables
future triggers, not already started/queued runs. Resume enables future triggers
and possible model costs; it does not request an immediate run or replay missed
firings. Pause/resume preserve the definition and history. Delete removes the
definition and future triggers, with **no undo**; execution history stays in storage
but is no longer reachable through the deleted routine's UI. Deletion does not
cancel already started/queued runs, delete their output files, or disconnect any
external service. Stop/account changes revoke
pending proposals, definition edits invalidate stale approvals, and failed writes
do not arm an in-memory task. Spend-protection pauses and unsupported triggers
must be reviewed by the user in Automations before resuming; deleting them cannot
resume other protected tasks. This tool cannot operate on another agent's tasks
or add tools to automation runs.

The same tool also supports **creating and updating own time-based, GitHub/Slack/Linear/Sentry/PagerDuty event or mixed time/event OR routines**:
`action:"create"` requires `name`, `prompt` and either `schedule` or `trigger` (never both), with an optional boolean
`enabled` (defaults to true); the host assigns the owner and ID. `action:"update"`
requires an own routine `id` and at least one changed field. Omitted fields stay
unchanged. Names are limited to 80 characters, tasks to 32,000, schedules to 256,
and each agent to 50 definitions. Cron, aliases and `@every` intervals from one
minute through 366 days are supported. A new schedule pins the app's time zone,
unless a valid `TZ=` / `CRON_TZ=` prefix overrides it; updating a legacy definition
without a time zone requires supplying a schedule to pin one explicitly.

Every write shows the **complete before/after task, schedule, time zone and enabled
state** for explicit approval. New or rescheduled tasks start after approval,
without catch-up or an immediate run. Name/prompt-only edits retain the next-run
date. Current execution history is preserved, and already started/queued runs keep
their original task. Spend protection cannot be bypassed with a new ID or enabled
flag; disabled drafts remain possible. These writes share the four-change budget,
storage quota checks, cancellation fences and atomic persistence.

An individual GitHub condition looks like
`{"type":"github","repo":"owner/repo","events":["pr-opened"],"userAllowlist":["author"]}`.
The complete repository, event set, user filter and optional `ciBranch` appear in
the approval preview. Empty/omitted `userAllowlist` allows everyone; PR events
filter the PR author, review events require both author and actor, and issue
assignment filters the actor. CI ignores the user filter and requires one branch.
It currently covers **individual completed push workflows** (`workflow_run` success,
failure or timed_out), **not** the reference's aggregate settled checks or PR CI.
Matching occurs before batching so unrelated deliveries are not passed to the model.

An individual Slack condition looks like
`{"type":"slack","channel":"C123","match":{"kind":"reaction","emoji":["eyes"]}}`.
Use a concrete conversation ID (C/G/D...) or `*`, not a channel/user name.
`*` covers all delivered conversations across configured connections, not every
conversation in Slack. Match kinds are `message`, `mention` (app/bot mentions),
`keyword` (required keyword, up to 120 characters) or `reaction` (up to 8 emoji
short names; omitted/empty means any emoji). Verified webhook matching accepts only
plain human messages and added reactions to messages; edits, deletions, bot/subtype messages,
removed reactions and file reactions are excluded. Mentions/reactions require
verified Slack event ingress; the existing channel-message path supports
message/keyword matching with its existing connector filtering, not webhook event
classification (it does not retain event subtypes). The full normalized condition appears in approval.
Name lookup and `bySelf:true` are rejected: Filicon cannot reliably map the
signed-in human to a Slack identity. No filter is silently discarded.
Emoji qualifiers such as `::skin-tone-2` are also rejected rather than being
silently reduced to a broader base-emoji filter.

An individual Linear condition looks like
`{"type":"linear","event":{"case":"statusChanged","statusIds":["aaaaaaaa-0000-0000-0000-000000000001"]}}`.
Also supported: `issueCreated` (without `statusIds`) and cycle completion, e.g.
`{"type":"linear","event":{"case":"endOfCycle","cycleIds":["dddddddd-0000-0000-0000-000000000001"]},"teamIds":["bbbbbbbb-0000-0000-0000-000000000001"]}`.
Optional `teamIds` narrows all three cases; `projectIds` narrows issue cases only.
`statusIds` matches the **new** status and is only allowed for `statusChanged`;
`cycleIds` is only allowed for `endOfCycle`. Native cycles have no project
relationship, so a cycle proposal with nonempty `projectIds` is rejected:
omit it or use an empty list, never discard a requested project restriction.
Each raw list accepts up to 50 exact UUIDs; omitted/empty means any. Use actual
IDs from your service, not the illustrative IDs above, names or guessed IDs.
UUID case and repeated values normalize before the full approval preview.
Unknown fields, nulls, wrong types and invalid filters reject the entire
proposal, including inside groups and disabled proposals. The same constraints
apply to core writes. No invalid filter is silently removed.

An individual Sentry condition looks like
`{"type":"sentry","event":{"case":"issueAny"},"projectIds":["123"]}`.
Supported cases are `issueCreated`, `issueResolved`, `issueAssigned`,
`issueArchived`, `issueUnresolved`, and `issueAny` (only those five issue cases,
not every Sentry event). Optional `projectIds` accepts at most 50 exact decimal
ID strings of 1–200 ASCII digits each; omitted/empty means any project. Use real
project IDs, not the illustrative ID above, names, slugs or guessed IDs. Values
are sorted/deduplicated after validation; leading zeros are preserved for exact
matching. No numeric coercion, trimming, unsupported filters or invalid members
are silently accepted. Core validation also rejects malformed direct writes and
conversions of legacy raw-action definitions. No existing definition is migrated.

An individual PagerDuty condition looks like
`{"type":"pagerduty","event":{"case":"incidentAny"},"serviceIds":["PF9KMXH"]}`.
Supported cases are `incidentTriggered`, `incidentAcknowledged`,
`incidentResolved`, `incidentEscalated`, and `incidentAny` (only those four
incident cases). Optional `serviceIds` accepts at most 50 exact, case-sensitive
ID strings of 1–200 characters each; omitted/empty means any service. Use real
service IDs, not the illustrative ID above or guessed IDs; no name lookup is
performed. IDs are opaque: case is preserved, and no numeric conversion or
trimming occurs. Empty strings, whitespace, control characters and the wildcard
`*` are rejected. The raw list is validated before sorting/deduplication.
Unknown fields, nulls, wrong types and invalid filters reject the whole proposal,
including a mixed group. Core validation also rejects malformed direct writes
and model conversions of legacy raw-event definitions; no existing definition
is migrated.

Combine 1–8 cron/GitHub/Slack/Linear/Sentry/PagerDuty conditions with `{"type":"group","listeners":[...]}`
or a bare `trigger:[...]` array. This is **OR, not AND**: any one condition can
fire the same prompt, with each condition retaining its own filters. A delivery
matching multiple conditions is included once; distinct deliveries can cause
additional runs/costs. Delivery IDs are scoped to their connector, including
after reload. Every member must be valid; empty, oversized, nested,
generic-event or other-platform groups are rejected as a whole. Exact normalized
duplicates collapse, order is canonicalized, and one remaining member becomes
a single trigger. The complete normalized group and relevant time/platform
disclosures are shown for approval. No connection is implicitly added.

Time members use `{"type":"cron","schedule":"@every 1h"}` (also valid alone).
Groups can mix time and event conditions or contain only time conditions. Each
time member pins the app time zone before approval, unless a valid `TZ`/`CRON_TZ`
prefix overrides it. Each model-proposed time condition must have a next run
within 366 days; intervals range from one minute to 366 days. Unknown fields or
any invalid condition reject the entire proposal, including disabled proposals.

This requires an **existing authenticated connection**; creating a definition
does not install/start webhooks, log in to an external service or grant new tools. Already queued
events can match after approval. Updates may switch between time, GitHub, Slack, Linear, Sentry, PagerDuty and mixed OR
triggers, while an omitted trigger is preserved. Unknown events, malformed filters,
other platforms and generic events are rejected. A top-level `schedule` cannot
accompany `trigger`. The manual new-routine controls are described below.
This is not full reference parity.

Flat `anyOf` definitions select the
earliest cron/interval member alongside event members. Coincident time members
produce one run; all members share the last-run anchor, so an event or manual run
also resets interval timing. Pause/resume does not backfill. Loading a legacy
definition with no next-run date does not silently arm it. Mixed proposals show
the full before/after definitions and time-zone, interval-reset and model-cost
disclosures for explicit approval. The manual new-routine form also supports
flat OR listeners. Saved routines now have a dedicated **Edit** button; the
supported manual editing subset is described below.

In **Automations → New routine**, Linear, Sentry and PagerDuty now have event
menus instead of free-text event names. Linear offers issue creation, status
changes and cycle completion with explicit team/project/new-status/cycle UUID
fields as applicable. Sentry offers five issue actions plus any supported issue
event, filtered by exact decimal project IDs. PagerDuty offers four incident
actions plus any supported incident event, filtered by case-sensitive service IDs.
Defaults use the same case names as verified ingress events. Each optional comma
list accepts at most 50 raw entries before deduplication; blank means any. Empty
comma segments, invalid IDs, unsupported events and incompatible filters block
creation with a localized explanation. Switching Linear events retains entered
filters so the user can clear incompatibilities; no restriction is silently dropped.
These controls and notices cover all seven UI languages and preserve platform
brand names. They do not install accounts/webhooks or migrate existing routines.
Authenticated fixture matching, isolated persistence/OR tests and native rendering
are verified, not live external-account end-to-end behavior.

GitHub now uses checkboxes for its 14 supported events, with a concrete
`owner/repository`, exact CI branch and optional user logins. Slack uses
conversation IDs (`C/G/D...`) or `*`, with separate keyword and emoji fields.
Both creation and editing reject unknown cases, truncation, empty comma segments,
missing CI branches and incompatible retained Slack filters. Limits apply before
deduplication (14 events, 50 logins, eight emoji names); no invalid restriction is
silently discarded. Slack channel/user names and self-only reactions are not
supported. A Slack app mention is not a mention of the signed-in human. GitHub
CI observes each completed push workflow separately, not aggregate checks; its
user filter is ignored for CI. Other GitHub events filter PR owners, both review
actors and PR owners, or the actor assigning an issue, not the assignee. These
controls disclose their existing-ingress requirements and do not connect accounts.

In **Automations → Edit**, change a saved routine's name and instruction, plus
cron/interval, generic connector events, supported GitHub/Slack/Linear/Sentry/PagerDuty conditions,
the restricted Teams conditions described below, or a flat OR of up to eight of
those conditions. Other platforms, legacy and unknown formats expose
their original trigger as read-only; name/instruction edits preserve it without
migration. Untouched members keep their original IDs and time-zone representation.
Saving preserves the owner, enabled state, spend protection, history and in-flight
execution, and does not run the routine immediately. Changed time conditions
restart from save time; metadata or event-filter edits do not reset an unchanged
time condition. Already queued events may match new conditions and incur model
costs. A stale definition, deleted routine, cancelled editor, archived owner or
account change blocks an uncommitted save. Failed storage keeps the draft and
the last persisted definition. These controls have seven-language coverage;
Full Teams runtime/identity support, identity/name lookup, aggregate GitHub checks
and live platform parity remain open. Existing Slack name-based or self-only
conditions remain read-only, not silently changed into unrestricted conditions.

Generic connector events use an exact connector UUID and case-sensitive event kind
(1–128 characters, no control characters or surrounding whitespace). There is no
name lookup, connection creation, or liveness check. The existing connector must
already deliver events. Filters must be a JSON object, not an array or scalar;
duplicate keys (including escaped equivalents), malformed syntax and exceeded
bounds are rejected. All top-level fields must match; nested objects match in full
regardless of key order, arrays in order, strings by decoded Unicode spelling,
and types without coercion. Decimal numbers compare exactly without floating-point
rounding (`1`, `1.0` and `1e0` are equal; `true`, `1` and `"1"` are distinct).
An explicit `{}` matches any valid object payload from that connector and kind.
Invalid legacy conditions remain stored and read-only, but their event branch
never matches; metadata edits preserve the original bytes. Other valid OR members
and explicit Run Now retain their existing behavior.

Filter limits: 16 KiB, depth 16 (root at zero), 4,096 values including containers,
256 characters per number and absolute written exponent at most 10,000. Matching
payloads are limited to 1 MiB and the same depth/value/number bounds; malformed,
ambiguous or oversized payloads never match, even with empty filters. The manual
editor shares service validation and supports flat mixed OR conditions, preserving
untouched raw JSON. This is Filicon-native hardening, not a reconstructed cloud
feature. Agent `update_state` generic-event creation/update remains unsupported;
no new tool or external account permission is granted.

Linear ingress: verified Issue/create
webhooks expose `issueCreated`; Issue/update exposes `statusChanged` only when
`updatedFrom.stateId` proves a change to a valid current `data.stateId`. Unrelated
edits and ordinary Cycle updates are not inferred to be status/cycle-end events. The legacy
entity event (`issue`) remains available; existing `primaryIDs` filter actual team
IDs and `secondaryIDs` filter project IDs, never the issue ID as a missing-team
fallback. A dedicated Linear trigger keeps those legacy storage keys; old definitions
without `statusIDs` retain their original meaning. Model-written definitions
support new-status filters and the explicit cycle-completion conditions below.
No legacy definition is silently converted or enabled. The manual new-routine
form uses the same supported event cases and strict filter validation.

Linear issue and legacy events use `Linear-Delivery` as their delivery ID, falling back to a signed-body
digest when omitted; `webhookId` identifies the configured webhook, not an event.
The signed numeric `webhookTimestamp` is required and checked against the existing
replay window (300 seconds by default). An unsigned timestamp header cannot
override it. The signed-body digest also prevents a repeated request from reaching
the sink by merely changing headers, including after restart within that window.
Signature and payload semantics were checked against the
[Linear webhook documentation](https://linear.app/developers/webhooks).
Existing receipts are not migrated or replayed; delivery deduplication remains
bounded by the existing ingress window and automation history. A public endpoint
or Linear connection is not created by these changes.

The **native Linear cycle-event adapter** classifies `Cycle/update` as
`endOfCycle` only when `updatedFrom.completedAt` is explicitly null and the new
`data.completedAt` is a valid, nonfuture timestamp with an explicit time zone.
It requires cycle and team UUIDs. Editing `endsAt`, archiving, progress updates,
already-completed snapshots, or the clock merely passing an end date do not
prove this transition. Both scheduled and early completion can qualify.
This adaptation uses Linear's [Cycle completion semantics](https://github.com/linear/linear/blob/3addb24bdf771700da1c050742e70e645cc7e36a/packages/sdk/src/schema.graphql)
and [Cycle webhook fields](https://github.com/linear/linear/blob/3addb24bdf771700da1c050742e70e645cc7e36a/packages/sdk/src/_generated_documents.ts),
not the reference cloud backend's preclassified notification or a local polling
schedule. It has not been validated against a live Linear account.

Cycle conditions can filter exact team and `cycleIDs` UUIDs (model proposals use `cycleIds`). The native
Cycle payload has no project association, so project-filtered cycle conditions
fail closed; no project is inferred from issues. Status filters on cycles and
cycle filters on issue events cannot be silently ignored. Missing stored
`cycleIDs` means no filter; explicit null or a wrong type fails decoding. Old
entity labels such as `cycle` remain entity events, not evidence of completion.

A completion's event identity combines the cycle UUID and completion time at
millisecond precision, scoped by the connector in automation history. Equivalent
timestamp offsets and changed delivery IDs/retry envelopes do not duplicate a
retained completion. A different cycle or later completion is distinct. Ingress
still verifies the signature and fresh signed `webhookTimestamp`, with the
existing body-digest replay cache. Protection is bounded by retained history,
not permanent. No definitions are migrated or automatically enabled. Group and
mailbox agents can now propose their own cycle routines through `update_state`
create/update, alone or in a flat time/event OR group. Full before/after task,
trigger, enabled state, pinned time zones and seven-language disclosures require
explicit approval. Existing ownership, cancellation, spend guard, capacity and
durable-receipt protections remain in place; changing a definition retains its
run history. Approval does not request an immediate run or grant tools/permissions.
The manual new-routine form also offers cycle completion. It does not add polling,
name/project lookup or the reference backend's cloud project relationships.

Sentry ingress now distinguishes the documented issue actions (`created`,
`resolved`, `assigned`, `archived`, `unresolved`) as `issueCreated`,
`issueResolved`, `issueAssigned`, `issueArchived`, and `issueUnresolved`.
`issueAny` matches only those recognized issue events, not comments, alerts,
installation events, or unknown actions. Classification requires the `issue`
resource header and a valid decimal-string issue ID. Canonical `primaryIDs`
filters use `data.issue.project.id`, never a slug, issue ID, or installation;
missing/malformed project IDs do not satisfy a specified filter. An empty
project filter means any valid issue. Secondary filters are unsupported for
these canonical cases and fail closed. Old raw-action definitions retain
their legacy `event`/`primaryId`/`secondaryId` matching and storage format.
No definition is rewritten or automatically enabled.

Sentry signs only the raw body. Its digest is now both the ingress nonce and
event identity; unsigned `Request-ID` (or the old `sentry-hook-request-id`
alias) is diagnostic metadata, not a way to create a new execution. Identical
bodies therefore coalesce even if request headers differ. The bounded ingress
cache survives restart; retained automation history also deduplicates the
same digest. This is **not permanent replay protection** or authenticated
freshness: after both records expire, an old correctly signed payload can be
accepted again. Existing receipts are not migrated. A supplied Filicon
timestamp still undergoes its existing optional check, but is not signed by
Sentry. Behavior follows the [Sentry webhook envelope](https://docs.sentry.io/integrations/integration-platform/webhooks/)
and [issue payload](https://docs.sentry.io/integrations/integration-platform/webhooks/issues/).
Sentry own-routine proposals now use the same full approval, ownership, spend,
cancellation and persistence checks in group/mailbox turns, including mixed OR
conditions. Seven-language approval previews disclose project scope, supported
cases, bounded replay protection and future costs. A specialized new-routine form
is available; manual editing of saved definitions and live-account validation
remain unsupported/unverified. This does not
install/start connections or expose an endpoint.

PagerDuty V3 ingress maps `incident.triggered`, `incident.acknowledged`,
`incident.resolved` and `incident.escalated` to `incidentTriggered`,
`incidentAcknowledged`, `incidentResolved` and `incidentEscalated`.
`incidentAny` covers only those four cases. Canonical classification requires
a nested `event` with a valid event ID, `resource_type: incident`, and incident
data with a valid ID and `type: incident`. Canonical `primaryIDs` filters match
the exact `event.data.service.id` of a `service_reference`, never a summary,
incident ID, subscription ID or fallback field. Empty service filters mean any
valid incident; secondary filters fail closed. Legacy raw-event definitions
keep their original matching and storage, without migration or auto-enabling.
This follows the [PagerDuty V3 payload documentation](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/01-Overview.md).

PagerDuty signature verification now accepts only comma-separated `v1=` HMAC
candidates, allowing secret rotation without accepting unversioned signatures.
The signed-body digest keys the bounded replay cache; signed `event.id` identifies
the event for retained automation history. Missing legacy IDs fall back to the
digest, while malformed or overlong IDs are rejected rather than truncated.
Unsigned `X-Webhook-Id` (or the old `x-pagerduty-delivery` alias) is diagnostic only.
`occurred_at` is event time, not delivery freshness: legitimate deliveries may be
retried long after the event. The optional Filicon timestamp check remains, but
is not PagerDuty-signed evidence. Deduplication is not permanent after both cache
and history expire; old receipts are not migrated. See PagerDuty's
[signature protocol](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/04-Signatures.md)
and [delivery behavior](https://github.com/PagerDuty/developer-docs/blob/main/docs/webhooks/02-Behavior.md).
PagerDuty own-routine create/update proposals now use the same full approval,
ownership, spend, cancellation and persistence checks in group/mailbox turns,
including mixed OR conditions. Seven-language approval previews disclose the
exact service scope, four incident cases, bounded replay protection, event-time
limitation and future costs. Specialized manual creation and editing forms are
available; live-account validation remains unverified.
Verification uses isolated signed
fixtures; it does not create a connection or public listener.

Teams outgoing-webhook ingress now distinguishes transport authenticity from
application-user authentication. HMAC and `from.aadObjectId` do **not** establish
that a sender is signed in to Filicon. Conditions with
`blockUnauthenticatedUsers: true` therefore fail closed, including previously
queued payloads claiming `authenticated: true`. Existing definitions are not
rewritten or relaxed. **The manual Teams editor retains this default, so its
Teams event conditions currently cannot run**; the editor prominently discloses this.
Other listeners in an OR routine and explicit manual runs are not disabled.

Manual creation and **Automations → Edit** share strict Teams scope validation:
one tenant UUID, 1–50 Graph UUIDs or exact opaque Bot team IDs, and optionally
up to 50 exact channel IDs. Empty channels means all channels of the selected
teams. Limits apply before deduplication; empty comma items, wildcard `*`,
whitespace/control characters within IDs, or IDs over 200 UTF-8 bytes are rejected.
Tenant/Graph UUIDs are normalized only when a condition is changed; opaque IDs
retain case. A literal, nonempty message filter of at most 120 characters is
required, with no control characters. Newlines are not silently rewritten or
truncated. Long fields wrap in the seven-language editor.
Conditions using regex, allowing unauthenticated users, empty filters or invalid
scope remain read-only, including their containing OR group. Name/instruction
edits preserve the original trigger. Unchanged members stay intact; changed
conditions are checked again at the atomic manual-save boundary. This adds no
policy-relaxation switch, account connection or event
execution capability, and does not migrate existing definitions.

Group/mailbox agents may now propose their own Teams routine creation or update
through `update_state`, using `type: "microsoftTeams"`, `tenantId`, `teamId` and/or
`teamIds`, optional `channelIds`, and required literal `messageContains` text.
The team aliases merge with a combined limit of 50 raw entries before deduplication;
channel lists have the same limit. UUIDs normalize; opaque IDs retain exact case.
`messageContainsIsRegex` must be false and `blockUnauthenticatedTeamsUsers` true
(their defaults). Null, unknown fields, wrong types and invalid filters reject
the whole proposal, including a mixed OR. Full before/after approval is required;
the durable boundary revalidates the policy and preserves history, spend guards,
owner identity, revision and cancellation fences. Legacy relaxed/regex definitions
cannot be converted by the model. Approval and tool results explicitly disclose
that this saves a **definition, not an executable Teams listener**. Other approved
OR branches and explicit Run Now can still run and incur model costs. This does
not connect an account, grant tools, authenticate users or start external services.

The native adapter only classifies bounded `message` activities from `msteams`
channel conversations with tenant, team, channel, conversation, sender and
activity IDs plus string text (up to 4,000 characters). Edits, deletions, invokes,
other activity types and incomplete contexts cannot trigger a Teams condition.
Graph UUID filters use `channelData.team.aadGroupId` when supplied; legacy Bot
Framework team filters still use `channelData.team.id`. These are separate
namespaces, with no name lookup or inference when Graph metadata is missing.
Tenant/Graph UUID comparison ignores case; opaque Bot/channel IDs remain exact.

Even when a stored condition explicitly permits senders without Filicon sign-in,
it must have a nonempty text filter (substring or regex). The reference's empty
filter means root posts only, whereas the Activity protocol makes `replyToId`
optional. This adapter does not guess root status from its absence or parse
opaque conversation IDs. Explicit text filters may match replies. This is a
conservative native adaptation, not the reference cloud's `platformMatched`
user/regex service or Graph subscription coverage. See Microsoft's
[outgoing-webhook protocol](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-outgoing-webhook),
[TeamInfo fields](https://learn.microsoft.com/en-us/javascript/api/%40microsoft/agents-hosting-extensions-teams/teaminfo?view=agents-sdk-js-latest),
and [Activity specification](https://github.com/microsoft/botframework-sdk/blob/main/specs/botframework-activity/botframework-activity.md)
(checked 2026-09-20).

The HMAC body digest still protects the ingress replay cache. Supported message
identity additionally hashes tenant/Bot-team/channel/conversation/activity IDs,
so a re-signed retry or changed timestamp cannot execute a retained message
again; optional Graph metadata does not alter its identity. Invalid supplied
activity IDs are rejected rather than truncated. Identity is bounded and
connector-scoped; there is no permanent deduplication after cache/history expiry,
signed delivery freshness, or migration of old receipts. Seven-language notices
explain these limits. This does not add a user
authentication control, account login, Graph polling/subscriptions or a public
webhook, and has not been validated against a live Teams account.

All native webhook providers share the same admission boundary. After secret
lookup, the listener rechecks the route revision and listener generation, then
validates timestamp freshness where the provider supplies it. Disabled, removed,
replaced or disable/re-enabled routes cannot admit an older waiting request;
stopped/rebound listeners also reject buffered requests from their old connections.
Failed route saves leave the previous runtime definition intact.

A replay nonce is persisted before queue handoff and remains reserved while the
handoff is pending. A confirmed full-queue rejection returns HTTP 503 and releases
the nonce for a still-valid signed retry. If releasing that marker cannot be
persisted, the request instead returns 500 and retains bounded replay protection.
An accepted event keeps its marker even if a later state/audit write fails; its
in-memory replay window is refreshed at handoff completion. A failed initial
reservation never calls the queue. Stop/revocation after handoff does not retract
already admitted work.

Queued event identity includes both connector ID and external event ID, so two
connectors with the same delivery ID cannot suppress one another. A verified,
re-signed copy already waiting in the same queue is acknowledged without a second
entry, even at capacity. Signature, rate, payload and replay checks still apply.
Acknowledgement means queue admission, **not** routine completion. The queue is
in memory: this is not crash-safe delivery, permanent deduplication or exactly-once
execution. A crash between reservation and handoff remains an uncertain outcome;
the retained bounded marker is not automatically released. Tests use isolated
queues and secrets, not live external accounts.

In group and mailbox turns, agents can propose creating, joining or leaving an
account-local collaboration project with
`update_state(target:"project", action:"create"|"join"|"leave", project:"exact-slug")`.
Create requires `name` (1–200 UTF-8 bytes) and accepts `description` (up to 1,000
UTF-8 bytes); join/leave accept no other fields. Slugs are lowercase ASCII
letters/digits separated by single hyphens, up to 64 bytes, never filesystem
paths. Text rejects control characters and trims outer spaces. The host fixes
the requesting agent and account; it cannot change another agent's membership.

Each change needs fresh explicit approval, even with automatic tool approval
enabled. The card shows the project metadata, membership before/after and member
counts. Creating an existing slug joins it without overwriting its metadata;
leaving preserves the project and all other members. Already joined/left is a
no-op error. Each account has at most 50 projects, including empty projects.
The directory exposes only slugs, names and the requesting agent's joined state;
project metadata is account-shared information, not a place for private facts or
credentials. Pending approvals become stale when that project's state changes,
including leave/rejoin cycles. Stop, account changes and agent archival revoke
uncommitted changes; failed writes roll back, and successful call replays do not
write again. These operations share the existing four-change turn budget.

These are account-scoped records in the agent store, not filesystem-backed
reference project folders. Joining permits recall/search of approved project
facts from current and departed writers. Leaving preserves those facts but
stops future access; rejoining restores access. Already-sent messages remain.
Membership does not create a chat, grant folder access, start work or share
private memory. There is no project rename/delete or dedicated manual project editor yet. Existing stores
load with an empty project list; old groups, memories and permissions are not
migrated. Revision checks protect the running service, not concurrent external
edits to its JSON file. This is a bounded native adaptation, not full project
parity or live-model acceptance testing.

In group and mailbox turns, agents can propose remembering or forgetting a short
fact using `update_state(target:"memory", action:"write"|"forget", fact:...)`.
Each change needs explicit approval. Omitted scope (or `scope:"agent"`) remains
private to the recording agent in this account. Explicit `scope:"user"` proposes
sharing with **all current and future agents in this account**, including agents
outside the current group, through their configured models during group/mailbox
turns. The approval shows this wider audience; existing facts are not migrated
to shared memory. Models can forget only facts they recorded, using the exact
text and original scope. **Agents → Edit → Agent memory / Shared user memory / Project memory**
lets the user inspect and forget records, including shared facts from another
agent. Forgetting stops future injection, not already-sent messages or in-flight
requests. Each private agent store and the entire shared account store have
separate limits of 48 facts / 8 foundational facts / 12,000 characters. This is
bounded `profile`/`log`/`note` memory, not automatic transcript capture,
memory in other execution entry points, or full parity with the reference runtime.

Explicit `scope:"project"` additionally requires `project:"exact-slug"` and
current membership. Facts are shared only with current and future members of
that project in the same account and their configured models, including agents
outside the chat. The card shows the project, author, member count and full fact;
writing and forgetting each require fresh approval, even when auto-review allows
the tool. Models can forget only their own project records while joined. The
human editor lists all account project facts, labels the project and author,
and can forget a record even after its author leaves or is archived. The same
48-fact / 8-foundational / 12,000-character storage limits apply **per project
across all writers**, with at most 1,000 characters per fact. Private facts are
never automatically promoted to shared facts. Project membership changes,
including leave/rejoin cycles, invalidate pending memory approvals. Stop,
account changes, archival and failed storage cannot publish uncommitted facts.

Recall is read-only and bounded separately from storage. Within each private/shared
and foundational/recent pool, literal keyword overlap with the **current user or
incoming peer message** ranks first. This can surface an older relevant approved
fact that would otherwise fall outside the prompt budget. Older transcripts,
images, files, other agents' private facts and other accounts are not queried.
Each tool captures its own immutable query terms, not a session-wide last query;
no query or new fact is persisted by recall. With no matching terms, the existing
ranking is unchanged. Ties use date, with low-importance `note` facts weighted at
half the importance of `log` facts on a 30-day relative scale, then stable IDs.
Foundational facts retain separate budgets.

Lexical matching examines at most the first 4,096 Unicode scalars and 128 unique
terms of each query/fact. It uses whole alphanumeric words of 2–64 scalars (with
common English/French/Spanish stopwords excluded) and adjacent Han/kana/Hangul
pairs, ignoring case, accents and character width. Repetition does not increase
the overlap score. This is a native adaptation of the reconstructed reference's
keyword selection, which was used to gather archived facts for extraction; it
does **not** implement that extraction pipeline, semantic/vector search or
cross-language synonym matching. Relevance is not proof of truth or permission
to share, and cannot bypass the current task's approval gates.

Case/whitespace-equivalent facts collapse within each scope and profile/recent
pool (and within the same project), preserving the newest original text and author. Nothing is automatically
deleted or expired. The runtime reports how many records were omitted; the editor
still lists every saved record. JSON recall budgets (including UTF-8 metadata and
escaping) are 8,000 / 4,000 bytes for private profile / recent pools and
4,000 / 2,000 bytes for shared user profile / recent pools. Joined projects have
an additional aggregate pool: at most 8 foundational / 15 recent facts and
4,000 / 2,000 JSON bytes **across all joined projects**, not per project.
Oversized records are
omitted intact, never truncated. This is not semantic conflict resolution,
automatic transcript extraction, or arbitrary archival file access.

In these same group/mailbox turns, agents can call the read-only `SearchMemory`
tool to find **already approved saved facts** that were omitted from automatic
recall. Use an optional literal substring `query` (at most 256 Unicode scalars;
ignores case, accents and width), and `scope: "agent" | "user" | "project" | "all"`
(default all). Project scope covers joined projects; optional `project:"exact-slug"`
narrows it to one joined project and is rejected with any other scope.
Empty/omitted query browses; whitespace-only input is rejected. The host
binds agent and account identity: private peer facts and other accounts are
excluded before matching, counting, or paging, as are unjoined projects.
Results retain original text, scope, project slug when applicable, tier, author,
recorded time and whether this agent can forget the record.
Reading shared facts does not permit deleting another author's records.

Each response contains at most eight complete facts and 8 KiB of JSON, with
`totalMatches`, `skippedOversizedCount` for that page, and an optional `nextCursor`.
Oversized facts count as matches but are skipped intact; inspect them in the
memory editor. Pass **only** the cursor to continue in the same agent/turn/session.
A change to the selected visible store or relevant project membership (including
leave/rejoin cycles) invalidates its cursor; start a new search
instead of using stale pages. No facts are cached in cursors. Up to 32 searches
are allowed per originating request, shared by its agents and separate from the
four-change approval budget. Stop/session closure or an archived owner prevents
further searches. Search does not save, share, forget, or grant filesystem access;
results remain untrusted data, not authority, and private facts must not be
disclosed merely because they were retrieved. Raw tool results are not copied to
the common group/mailbox history; any final message still needs to respect the
current task's disclosure boundaries.

`SearchMemory` is a Filicon-native counterpart to the reconstructed reference's
ability to Read/grep older saved memory files, **not** a claim that the original
exposed a tool of that name. It does not search arbitrary files, old transcripts,
other accounts, unjoined projects or semantic/vector indexes, nor implement automatic
memory extraction. Tests use isolated stores and fixture model providers, not
live accounts.

## Requirements

- macOS 14 or newer
- Xcode 26 or a compatible Swift 6 toolchain

## Build and test

### Xcode (complete app, including local tools)

1. Stop the old Run session and close the Xcode window opened from
   `Package.swift` / the repository folder. Open **`Filicon.xcworkspace`**.
2. Select the shared **Filicon App** scheme and **My Mac**.
3. **⌘B** builds the app; **⌘R** builds and runs it under the debugger.
4. **⌘U** runs the app-hosted bundle/XPC integration tests with isolated test
   data. It does not use your groups, chats, or authorized workspace folders.

The native project links the existing Swift package libraries, builds and signs
the XPC service and both helper executables, and embeds them with all seven
localizations and pet avatars. No Apple developer account, manual copying into
`/Applications`, Ruby, or project-generation step is required for Debug runs.
Stop any older Filicon Run session before launching another copy against your
normal workspace. The automatically generated Swift-package **Filicon** scheme
is not the same as **Filicon App**; it launches only a bare executable.
If Xcode reports "already opened from another project or workspace" or missing
package products, close the old package window before reopening this workspace.

The **Track Resource Signing** build phase records a deterministic resource
digest as a declared bundle output. This makes localization/asset-only changes
participate in Xcode's normal CodeSign task; it does not re-sign manually or
disable signature checks. It checks file membership on every build, leaves an
unchanged digest untouched, and runs with script sandboxing enabled.

To regression-test resource-only incremental builds without editing this
checkout or launching an app:

```sh
ruby scripts/test-resource-signing.rb
python3 -B scripts/test-package-entitlements.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zsh scripts/smoke-xcode-resource-signing.sh
```

The smoke script retains an isolated source snapshot, build products and logs
under a printed temporary path. It checks all seven localizations, asset
addition/removal, and no-op builds with deep/strict signature verification and
the full Debug package verifier (metadata, helpers, XPC and entitlement policy).
This is Debug ad-hoc validation, not a production release or notarization check.

Debug uses ad-hoc signing by default. Rebuilding or switching launch methods
can change the app's signing identity and invalidate saved folder grants.
Filicon validates grants before reporting them as authorized: an invalid grant
shows **Reauthorize workspace folder** in the chat. Click **Choose Folder…**
and select the project again; you do not need to recreate groups or chats.
Do not copy old bookmark data or bypass security-scope checks to avoid this
prompt. Builds signed with a consistent development/distribution identity are
recommended for persistent everyday use.

The Debug XPC entitlement grants **read-only access to the exact built
`Filicon.app` bundle** so the sandboxed service can verify its client's signature
inside DerivedData. It does not grant access to the checkout or user documents.
The sandbox, signature check, folder grants, and per-operation approval gates
remain enabled. Release builds do not include this development-only exception.
The verifier accepts the canonical bundle path or its `/var` / `/tmp` spelling
only when the corresponding root-owned macOS symlink has the expected target.
It does not resolve arbitrary signed exception paths; user-created symlinks,
parent/child directories, extra paths, and read-write exceptions remain rejected.
Shipping verification still rejects all such exceptions and debugger rights.
Keep **Debug XPC services used by app** off in the scheme (the checked-in default):
attaching the debugger to the service makes Xcode re-sign it with broader
diagnostic entitlements. App debugging still works. XCTest itself also modifies
service entitlements, so its app-hosted tests are not a strict sandbox test.

To validate the normal Debug bundle and real sandboxed XPC read/write without
XCTest's extra access, first use **Product → Clean Build Folder**, then **⌘B**,
and run (substitute the built app's path):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zsh scripts/smoke-xcode-xpc.sh /path/to/Debug/Filicon.app
```

The smoke check verifies the source bundle, creates a diagnostic copy under
ignored `DerivedData`, and tests only fresh temporary fixtures. It verifies
exact entitlements, grant invalidation across two differently signed builds,
explicit fixture reauthorization, persisted-grant reload, list/write/read,
unknown-root denial, and revocation.
It never changes the original app or accesses your workspace data.

For all Swift package unit/integration tests, use the full Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Keep the Mac unlocked while running persistence/attachment tests: fixtures use
protected files, and reopening them while the session is locked can fail with
Cocoa 257 / POSIX 1. Do not disable file protection to make tests pass. UI render
fixtures yield between images; the default parallel run includes the complete
rendering matrix. Keep large render matrices parameterized by language and, when
needed, scenario so each bounded case does not include many rounds of main-queue
waiting. Concurrency fixtures should signal readiness explicitly, while retaining
the actual cancellation, ordering and timeout assertions. For a serial diagnostic
comparison, use:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
```

A serial pass does not replace a failed parallel run. Two live Codex integration
tests remain opt-in (see the live tool-bridge checks below); an ordinary suite
pass is not live-account, native XPC sandbox, or release-signing validation.

Maintainers can regenerate the checked-in project after bulk source-layout
changes with `ruby scripts/generate-xcode-project.rb` (`xcodeproj` gem 1.27).
Ordinary Xcode file/target editing does not require regeneration.

### Standalone / release packaging

Create a standalone ad-hoc-signed application bundle with:

```sh
./scripts/package-app.sh
```

Quit any running copy, copy the built `dist/Filicon.app` into `/Applications`
(back up an existing installation first), then open `/Applications/Filicon.app`.
The sandboxed tool service must be able to verify the parent app's signature;
running the bundle directly from a repository can fail this check. Do not
disable the sandbox or signature validation to work around it.

For installed everyday use, launch `/Applications/Filicon.app`. Xcode's Swift-package **Run** and
`swift run Filicon` launch an unbundled executable; Filicon explicitly promotes
that process to a regular foreground app so it appears in the Dock and accepts
keyboard input. Notifications and the local-tool XPC service require the packaged app. Stop the current
Xcode run before launching the packaged version to avoid two copies using the
same workspace.

The Swift package remains the source of truth for shared libraries and the full
test suite; the Xcode project supplies the native app/service packaging targets.
No Node.js or Electron runtime is required.

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

Channel storage now rolls back failed writes before reporting success. Removing
or disabling a connection stops its listener only after persistence succeeds;
saving a replacement configuration stops the old listener until explicitly
started again. Suspended profile requests cannot overwrite a removed/recreated
connection or a newer profile request. Overlapping flushes reserve deliveries,
and a failed sending checkpoint prevents the network send. Already-started
sends/accepted callbacks cannot be recalled. If saving a send result fails, the
last durable `sending` state remains; existing restart recovery retries it with
the same idempotency key, not an exactly-once guarantee.

Group/mailbox agents can now propose disconnecting **their own single connection**:
`update_state(target:"channel", action:"disconnect", platform:"slack"|"discord")`.
Only those three fields are accepted (4 KiB maximum). Peer-owned or unassigned
connections cannot be removed. Multiple own connections on a platform are
ambiguous: choose manually in **Channels** instead; the tool never bulk-deletes.
Every proposal needs separate explicit approval, even with auto-review allow
rules. The card shows the exact connection, account/channel label, enabled state
and counts of local inbound, delivery, pending/in-flight and failure records.
Approval removes that connection and those records and stops its listener.
There is no undo; chat history and attachment files remain. Other connections
and routines are unchanged, and already accepted callbacks/sends may finish.
**Keychain credentials are retained**, since references may be shared; this does
not revoke remote OAuth grants or recall remote messages. Any successful channel
store write while awaiting approval invalidates the snapshot, including ABA
changes; this is a process-local fence, not cross-process file coordination.
Stop/account changes revoke pending proposals. Saving must succeed before a
durable receipt is recorded; failures roll back. Replay protection and the
four-change budget are shared with other agent state changes. Other channel
operations and platforms remain unsupported by this model route.

Codex CLI now uses its interactive **app-server dynamic-tool protocol** for
Filicon tool turns (verified with Codex CLI 0.144.4). It retains the selected
model and CLI-owned sign-in. Existing groups work without recreation. Only
Filicon's registered tools are supplied, and their existing review, workspace
authorization and permission checks still apply. Native CLI shell/browser/apps,
hooks, plugins and inherited MCP servers are disabled for this ephemeral turn;
unsupported server requests fail closed. No user Codex configuration is changed.
Older CLIs that lack the experimental dynamic-tool protocol must be updated;
protocol errors are surfaced, never silently replaced with a text-only reply.
Claude Code CLI remains text-only. This does not add a Gmail connector or grant
browser/email access: the required Filicon integration must actually be configured.

The offline suite covers the bidirectional codec, denied/cancelled approvals,
duplicate calls, cross-thread/cross-turn rejection, and startup timeout. An
opt-in smoke test uses the installed Codex CLI and account with synthetic data:

```sh
FILICON_CODEX_LIVE_TEST=1 swift test --filter CodexToolBridgeTests/installedCodexExecutesAnIsolatedHostTool
FILICON_CODEX_LIVE_TEST=1 swift test --filter GroupToolApprovalIntegrationTests/installedCodexResumesAfterStaleReadOnlyReplyAndRequestsWriteApproval
```

The second regression uses a temporary group and file, seeds a stale read-only
claim, then verifies a resumed task requests real host approvals before writing.
It does not use the user's saved groups or project folders.

Local workspace access is requested in the conversation. Before file/process
work, agents can call `local__workspace_folders` to discover authorized roots;
with no roots (or `choose: true`) the conversation shows a folder-selection card.
In group chats this card stays above the composer, outside the scrolling history.
The tool and sidebar show **Waiting for folder selection** rather than a thinking
spinner. Unanswered requests expire after five minutes without granting access.
The native folder picker saves only the directory the user selects. Existing
authorized folders can also be chosen directly in the card. Selecting a folder
resumes the pending task, but does not replace operation review or local tool
permission checks. If the selected root differs from a tool's proposed root,
that operation does not run; the agent receives the correct root for a new call.
Cancelling/stopping the request prevents execution, and stale selections cannot
revive it. Folder access can still be revoked in Settings.

Local process completion waits for both the child exit status **and** acknowledged
stdout/stderr EOF. While final output is draining, `isRunning` stays true and
`exitStatus` remains unset; a terminal snapshot's bytes and offset are stable.
Each pipe delivers one bounded 64 KiB chunk at a time, preserving its own order;
there is no total ordering guarantee between stdout and stderr. The existing
combined 10 MiB output cap still terminates an overproducing command.

If inherited pipe writers remain open after the direct child exits, collection
has a one-second drain deadline. After that deadline or Stop during this phase,
the terminal snapshot retains captured bytes and exit code with a `terminationError` indicating potentially
incomplete output, not an empty successful result. The app marks such results
as tool errors without discarding the diagnostic payload. Reader cancellation
acknowledges any already-read chunk before closing, and does not signal a reaped
PID/process group. This is not background-descendant supervision or a guarantee
of collecting output produced after the deadline. Existing command timeouts,
permission receipts, workspace authorization and run/generation checks remain.

Each tool-enabled response receives a current host permission snapshot, and
workspace discovery returns `host_tool_permissions` alongside the roots.
`ask` means the agent can request an operation and wait for approval; `never`
means it is blocked. The Codex CLI's native read-only sandbox is independent of
these Filicon host tools and remains read-only. Neither the snapshot nor folder
discovery is an execution grant or evidence that project I/O succeeded. Group
history is passed separately from the latest user request, so an old diagnostic
request or an earlier agent's read-only claim does not become a permanent limit.

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
