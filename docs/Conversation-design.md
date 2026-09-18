# Conversation-first desktop design

The September 2026 reference is the **app window inside** the supplied promotional screenshot, not the surrounding browser, player or purple background. Filicon keeps its own name, pet avatars and group-first navigation.

## Layout and appearance

- Warm ivory canvas, a slightly warmer sidebar, peach incoming bubbles and ink outgoing bubbles.
- A 224–260 pt chat sidebar, a flexible transcript, and a 280 pt group inspector.
- The inspector is inline only when the detail area is at least 780 pt wide; smaller windows open the same controls in a sheet.
- Chat rows show actual last-message text and time. Empty workspaces show an explicit create-group state, never invented conversation history.
- Agents and automations remain one click away. Channels, shared rooms, MCP, computer, plugins, account and hidden chats are in the Workspace popover.
- Light appearance matches the reference. The existing Light / Dark / System preference still works; dark uses a corresponding warm charcoal palette.
- Persistence warnings remain available in a bottom banner; native window controls retain their own titlebar hit targets.

## Working controls

The group inspector saves name, description and membership together. Validation runs before persistence, failed saves restore in-memory state, and changing only metadata preserves speaker order and history. Routine entries are derived from the group's real agents and navigate to automation management. There is no simulated Share or tool-connection control.

Creating a group uses a separate sheet. A group can create its first agent through the existing editor, including the built-in pet picker. Existing conversations, provider controls, attachments, search and keyboard shortcuts remain available. Unsent group drafts survive switching between groups in the workspace.

The Members section in both the inspector and new-group sheet provides **New member** and a pencil button beside each agent. Successful creation selects the returned persisted agent ID, even when another agent has the same name. Press **Save** in the inspector (or **Create group** in the new-group sheet) to apply membership changes; creation alone does not silently save other group drafts. Canceling group changes does not delete the already-created agent. Editing an agent saves its shared profile across groups, with an explicit notice; it never changes membership. The six-member cap disables new-member creation and unchecked rows while leaving editing and deselection available. Save failures remain visible in the editor, and saving cannot be submitted twice.

## Verification

### Group collaboration (September 18 correction)

The reference `grok-bot-0.18-reconstructed` has bounded multi-round collaboration,
not a fixed designer → engineer → reviewer workflow. Filicon now passes the group
name/goal, public member names/titles/descriptions, and named shared history to
each responder. Private instructions and private chats are not shared with peers.
History identifies new messages since the member's previous turn; the latest
user request remains separate from old diagnostic instructions.

Each request allows at most three rounds and ten published messages (two per
member turn). A member may continue after new peer text/tool activity, including
after an earlier PASS; they are not called again just to react to their own
output. Starting order rotates between requests and rounds. Repeated text from
the same member is suppressed within the request. PASS and member failures are
host-authored, localized notices, not fabricated assistant replies. Failed
members are not automatically retried within the same request. Existing groups
and histories need no recreation or migration.

Safety differences from the reference remain deliberate: only the latest user's
mentions choose the participating set; an assistant cannot expand it by writing
`@everyone`. Peer messages are not fresh user authorization. Existing host-tool
permissions, approval receipts, cancellations, and tool evidence remain in force.
Multi-round work does not grant new permissions or guarantee a particular model
will always make a useful contribution.

This repairs group turn-taking/context, not full original-runtime parity.
The text-only `SendMessage` tool now publishes directly through the host's
durable group callback, with a two-message turn limit and the existing ten-message
group budget. Once it publishes, final text is not posted again. Providers that
do not use it retain the final-response compatibility fallback.

### Cross-agent SendToAgent

Group inference now receives a real, request-scoped `SendToAgent` executor. The
host fixes the sender identity; the model supplies only an active recipient UUID
and a bounded message. It is not registered globally for anonymous direct chats.
New delegations require a real approval card showing the recipient and **entire**
outgoing payload, even when auto-review has a general allow rule. This is also
how a user can explicitly approve help from an agent outside the participating
group. A plain `@mention` still cannot expand the participant set.

Approval → durable enqueue → immediate queued acknowledgement → foreground group
responses finish → recipient wake in an independent inference context → explicit
SendToAgent reply → sender wake. That agent's own current-request history, retained
peer context for the same account/origin, and the explicitly delivered message
enter a wake; the sender's private persona
or complete conversation is never copied to a different agent. Incoming peer
messages have assistant role, not new user authority. A single reply to the
approved sender is part of the exchange; new handoffs require new approval.
Final wake reports and real tool activity are visible in the originating group.
The Agents > Messages view also shows queued/running/completed/failed/cancelled
delivery state separately from read/unread state.

Each user request has at most six queued messages/wakes in addition to the bounded
group rounds, with duplicate suppression, exact-call idempotency and a 180-second
deadline per wake. PASS never creates an automatic courtesy reply. Stop and
account changes fence queued work and cancel the active wake. Restart preserves
the mailbox but cancels unfinished deliveries instead of replaying old approvals.
Recipient tools use a fresh run ID and retain the originating conversation's
existing folder, local-tool, MCP and auto-review approval gates; delegation does
not grant file-write or external-action permission.

Manual Agents > Messages sends now enqueue and wake the recipient, even when the
view is not selected. Replies wake the sender; progress/delivery status appears in
the mailbox, with folder/MCP/delegation approval panels and Stop. A second send
in the same active mailbox is rejected rather than racing its grants/history.
`AgentConversationStore` retains up to 30 peer-context entries and stable inference
IDs across requests/restarts, isolated by account, origin conversation and agent.
It stores no system instructions, tools, approval receipts or permission grants.
`SendMessage` during a peer wake publishes to the originating group/mailbox.

The App now injects one `AgentExecutionScheduler` into group turns, peer/manual
mailbox wakes, subagent tasks, automations, workflows and inbound channel replies.
It provides a FIFO lane per agent across those origins; different agents can run
concurrently. Stopping a queued conversation removes only its own submission.
Execution timeouts start after acquiring the lane, not while waiting. ToolLoop
joins active host-tool cleanup before unlocking and closes its callback ledger
against late tool calls. Account transitions cancel queued work and interrupt
active subagent runtimes without releasing their lane before they unwind.

This remains narrower than the reference's full background session runtime:
contexts are origin-isolated, not a unified personal DM/group memory service.
Generic direct chats are not bound to agent profiles and retain conversation-only
serialization. There is no cross-process coordination, group target broadcast,
image payload or priority interruption. An uncooperative operation keeps its lane
until it unwinds; this is not a promise of immediate remote backend cancellation.
Unfinished work is cancelled at restart,
not replayed with stale approval. Model-facing CreateAgent/UpdateAgent remain
unwired despite existing UI/service CRUD. See [the itemized audit](Agent-collaboration-parity.md).

`AgentExecutionSchedulerTests` covers FIFO/parallel lanes, owner-specific Stop,
cleanup joining, late callback rejection, post-queue execution deadlines, and
steering/cancelling queued subagents. `AgentBackgroundExecutionTests` additionally
queues real AppModel group/manual/peer work against the same agent and checks
the shared automation, workflow and subagent wiring. Providers are scripted;
these are not end-to-end live Slack/Discord or model-service tests.

`AgentMessagingSessionTests` exercises real tool-loop dispatch with scripted
providers, reply wakes, context isolation, permissions scope, denial, spoofed
sender rejection, duplicate/replay protection, the six-message cap, timeout,
cancellation, persistence failure and restart compatibility.
`SendToAgentAppIntegrationTests` exercises the actual AppModel group path and
approval broker, including an outside-group recipient, approval/denial and a
late approval after Stop. These tests do not contact a paid/live model or alter
the user's groups.

`GroupCollaborationTests` covers handoffs, incremental context, privacy, PASS,
failure visibility, rotation, duplicate suppression and caps.
`GroupToolApprovalIntegrationTests/engineerAndDesignerPerformApprovedFileHandoffsInTheExistingGroup`
uses scripted providers but real local file tools, permission receipts and both
approval layers in an isolated workspace: create → design read → revise → reread.
It does not contact a live model or modify the user's project.

Earlier validation including SendToAgent: `swift test --no-parallel` reported 134 XCTest
tests and a 548-test Swift Testing run with no failures. The two opt-in live
Codex tests were skipped. Native `Filicon App` Debug build succeeded. All seven
catalogs passed the localization audit; PASS/failure notices rendered in all
seven languages, with Traditional Chinese and French PNGs visually inspected.

Prior validation (`324d62e`, 2026-09-18), including manual wakes, scoped persistent context,
text-only SendMessage, and preservation of published progress after failure/Stop:
134 XCTest tests and a 561-test Swift Testing run reported zero failures; the two
opt-in live Codex tests remained skipped. Native `Filicon App` Debug build and
`codesign --verify --deep --strict` passed. All seven catalogs have 1,393 keys and
zero missing keys. The message/approval view rendered in all seven languages;
Traditional Chinese and French were visually inspected, including long French
mailbox labels. One earlier full rerun hung in the existing cross-process file-lock
test's `Process.waitUntilExit` cleanup; that test passed in isolation and the final
full rerun passed. No live provider was contacted and the user's app was not restarted.

Subsequent per-agent scheduling validation (2026-09-18): 134 XCTest and a
575-test Swift Testing run passed with zero failures (two opt-in live Codex tests
skipped). Native Debug build, strict deep codesign verification and the seven
1,393-key localization audits passed. Regression coverage includes cancelled
shell-like runtimes that throw during cleanup. Full-suite findings also corrected
the CLI test's startup race, fenced MCP expiry/cancellation callbacks to their
exact request instance, and replaced the file-lock test's hanging synchronous
`waitUntilExit()` with an asynchronous termination notification. The last two full
runs passed; neither contacted live providers or restarted the user's app.

`ConversationDesignTests` covers the responsive breakpoint, draft separation, membership binding, persistence validation, transcript preservation and native SwiftUI rendering. To export review PNGs without changing the user's data:

```sh
FILICON_UI_REVIEW_OUTPUT=/absolute/temp/review-directory \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter ConversationDesignTests
```

The optional render fixture produces all seven interface languages, compact/narrow layouts, light/dark appearances, an empty workspace and a direct chat. The fixture's Chinese message content and agent names intentionally do not change when the interface language changes. These are review renders, not pixel-baseline comparisons or end-to-end provider tests.

Run `python3 scripts/localization_audit.py` and `scripts/package-app.sh` before delivery. Live QA should check the new-group sheet, workspace popover, settings, and reopening the packaged app. Do not seed demo groups into the user's workspace to take screenshots.
