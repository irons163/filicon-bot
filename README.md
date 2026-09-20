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

In group and mailbox turns, an agent can also propose changing **its own avatar**
with `update_state(target:"avatar", action:"set", pet_id:"hoots")`, or restore
the default Codex companion with `action:"clear"` and no `pet_id`. Each change
shows a preview and requires explicit approval, even with auto-review enabled.
Only the nine bundled companions are available to this tool; arbitrary files,
URLs, generated images and changes to another agent's avatar are not supported.
The approved change preserves names, private instructions, models and permissions;
resetting does not delete custom image files. Stop/account changes revoke pending
proposals, and an intervening manual avatar edit invalidates the old proposal.
Avatar, profile, memory and routine changes share the four-change limit per request.

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
cron/interval, generic connector events, supported GitHub/Slack/Linear/Sentry/PagerDuty conditions or a flat
OR of up to eight of those conditions. Other platforms, legacy and unknown formats expose
their original trigger as read-only; name/instruction edits preserve it without
migration. Untouched members keep their original IDs and time-zone representation.
Saving preserves the owner, enabled state, spend protection, history and in-flight
execution, and does not run the routine immediately. Changed time conditions
restart from save time; metadata or event-filter edits do not reset an unchanged
time condition. Already queued events may match new conditions and incur model
costs. A stale definition, deleted routine, cancelled editor, archived owner or
account change blocks an uncommitted save. Failed storage keeps the draft and
the last persisted definition. These controls have seven-language coverage;
Teams condition editing, identity/name lookup, aggregate GitHub checks
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
limitation and future costs. A specialized new-routine form is available; manual
editing of saved definitions and live-account validation remain unsupported/unverified.
Verification uses isolated signed
fixtures; it does not create a connection or public listener.

Teams outgoing-webhook ingress now distinguishes transport authenticity from
application-user authentication. HMAC and `from.aadObjectId` do **not** establish
that a sender is signed in to Filicon. Conditions with
`blockUnauthenticatedUsers: true` therefore fail closed, including previously
queued payloads claiming `authenticated: true`. Existing definitions are not
rewritten or relaxed. **The manual Teams editor retains this default, so its
Teams event conditions currently cannot run**; the editor now discloses this.
Other listeners in an OR routine and explicit manual runs are not disabled.

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
explain these limits. This does not add Teams model routine proposals, a user
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

In group and mailbox turns, agents can propose remembering or forgetting a short
fact using `update_state(target:"memory", action:"write"|"forget", fact:...)`.
Each change needs explicit approval. Omitted scope (or `scope:"agent"`) remains
private to the recording agent in this account. Explicit `scope:"user"` proposes
sharing with **all current and future agents in this account**, including agents
outside the current group, through their configured models during group/mailbox
turns. The approval shows this wider audience; existing facts are not migrated
to shared memory. Models can forget only facts they recorded, using the exact
text and original scope. **Agents → Edit → Agent memory / Shared user memory**
lets the user inspect and forget records, including shared facts from another
agent. Forgetting stops future injection, not already-sent messages or in-flight
requests. Each private agent store and the entire shared account store have
separate limits of 48 facts / 8 foundational facts / 12,000 characters. This is
bounded `profile`/`log`/`note` memory, not project memory, automatic transcript capture,
memory in other execution entry points, or full parity with the reference runtime.

Recall is read-only and bounded separately from storage. Foundational facts have
separate budgets; recent facts are ranked by date, with low-importance `note`
facts weighted at half the importance of `log` facts on a 30-day relative scale.
Case/whitespace-equivalent facts collapse within each scope and profile/recent
pool, preserving the newest original text and author. Nothing is automatically
deleted or expired. The runtime reports how many records were omitted; the editor
still lists every saved record. JSON recall budgets (including UTF-8 metadata and
escaping) are 8,000 / 4,000 bytes for private profile / recent pools and
4,000 / 2,000 bytes for shared profile / recent pools. Oversized records are
omitted intact, never truncated. This is not semantic conflict resolution,
automatic transcript extraction, or searchable archival memory.

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
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
```

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
