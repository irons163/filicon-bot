# Filicon data storage

All normal launches (packaged app, Xcode, and `swift run`) use:

`~/Library/Application Support/Filicon`

Startup prepares this directory before opening any stores. It does not discover,
read, migrate, or fall back to another application's private directory. An
unusable canonical directory stops startup with an error screen instead of
opening a different workspace. Symlinks in the chosen path or at its ownership
marker are rejected.

`FILICON_DATA_ROOT` remains an explicit opt-in override for isolated development
and testing. Tests must pass an isolated root when creating `AppModel`; they must
not initialize a production workspace implicitly. An invalid environment override
is ignored with a warning, and the same canonical root is validated before use.

The lower-level legacy-settlement API requires callers to supply both paths. It
is not used by application startup and has no default path into another app.

## Recovering data written by older Filicon builds

Older packaged builds could use `~/.cursor/sand`, while unpackaged launches used
the canonical path. Do not move that entire directory automatically: it may also
belong to other software, and the canonical directory may contain different data.

Before a user-authorized recovery:

1. Stop **all** Filicon instances, including Xcode runs; verify no process holds
   either workspace's databases open.
2. Identify Filicon-owned stores and compare both workspaces. Do not inspect or
   import another app's credentials or host state.
3. Back up both roots into a private, timestamped directory. Preserve SQLite WAL
   files with their databases and verify the copies before changing any paths.
4. Stage the selected Filicon dataset. Resolve differing records with the user,
   and validate SQLite integrity and expected group/member/message counts.
5. Preserve the old canonical directory as a backup, then rename the staged root
   into the canonical location. Keep the source intact; do not add a symlink.
6. Launch the rebuilt app, confirm the data root and records, and verify that no
   file handles point at the old directory.

`StartupRecoveryAppIntegrationTests` covers canonical startup for both launch
types, a populated foreign directory, ignored foreign symlinks, invalid overrides,
and failure before model/store creation. The regression tests use isolated roots.

## Canonical conversation read state (schema 17)

`conversations.sqlite3` stores direct-chat activity/view timestamps, the manual
unread flag and the unread count in `conversation_read_state`, outside serialized
`Conversation` snapshots. Saving old content therefore cannot overwrite a read
marker. `conversation_activity_receipts` retains counted message IDs even after
message deletion, preventing a restored message from becoming a second arrival.
Deleting a conversation removes both tables' associated rows; changing its exact
account/agent binding resets that owner's bookkeeping without recounting the old
messages. These are read markers, not execution permissions or tool approvals.

New completed user/assistant publications and their receipts/counts are committed
with the canonical message rows in one transaction. Incoming peer traffic,
unfinished messages and bookkeeping-only cards do not count. A correctly bound
direct secret-request card counts without adding a credential value to storage.
Migration from schema 16 and trusted legacy JSON import seed historical published
IDs without treating all old messages as new unread arrivals. An unfinished draft
can still become a new arrival when it actually completes after import.

Read actions require the exact current binding, including an explicitly unbound
chat. Automatic views can preserve manual unread; explicit read clears it without
regressing the timestamp. A final host commit guard may reject a stale action.
Ordinary saves cannot silently replace a missing or invalid read record with an
empty state. Recovery preserves the original bytes in private quarantine, records
rejected/missing state and conservatively leaves that chat needing attention.
Valid read markers and deleted-message receipts survive salvage; irrecoverable
receipt IDs cannot be reconstructed from absent message rows.

Native direct-chat viewing now records read state only for the current focused,
visible presentation. Manual unread survives focus/arrival callbacks until an
explicit Mark as read action or a human sidebar activation. The sidebar projects
canonical counts and offers both manual actions. A focus callback cannot supersede
an already queued human choice. An action captures its account, exact binding
and host lifetime before its Task is queued; account cycles, rebinding, deletion and
archival revoke it. Automatic callbacks also require the original presentation
epoch and newest-message witness. Loading/persistence refreshes canonical state;
stale refreshes cannot overwrite a newer action's projection. A failed read-state
write does not publish a zero unread count or answer an automation activity card.

For a non-group routine with one canonical bound direct chat, the host now feeds
the automation activity guard that chat's count and view time, not pending result
wakes. A repository-owned live observation is updated only after a successful SQL
commit. It holds a synchronous read-publication fence during guard decisions and
the guard's separate-store save. With unchanged owners, failed SQL publications
leave all projections unchanged. An ownership-change attempt conservatively
revokes the old projection even if that write fails; rollback cannot revive it.
Exact binding/uniqueness/hidden-state changes revoke the old projection, and an
account or owner lifetime change rejects old batches. Missing or corrupt
state and ambiguous bindings fail instead of selecting a wake-based source.
Explicit activity-card Mark as read also reads its unique bound canonical chat;
it does not answer a card, resume routines or alter execution consent. Unbound
legacy/text-only hosts explicitly retain their fallback.

Native activity checks now also appear in the owner's unique visible bound direct
chat as permanent transcript widget entries. Automation schema 3 retains an
immutable outbox destination, prompt ID and acknowledgment ID for each guard
stage. Nudge and paused stages have distinct entries even when they share a
guard ID. Schemas 1/2 migrate with an empty outbox; invalid schema-3 entries or
colliding IDs fail without rewriting the source. Reopening reuses those IDs;
merely viewing the card neither answers nor resumes it.

The first canonical-chat nudge also carries a host-only, process-local transition
into one admitted background wake. Its original owner, destination, card, counters
and revocable source survive scheduler pre-evaluation, not process restarts or
account/binding replacement. The native host publishes the permanent card before
the model can claim the app asked. A failed scheduled publication leaves the due
claim retryable; successful admission consumes the transition once. Manual and
reviewed-group wakes and later awaiting-ack firings carry no reminder. It is not
stored in definitions, a reminder queue or human chat history, and grants no
history, tool or memory access. Publication and run admission remain separate
commits with fresh post-await validation, not a cross-store atomic transaction.
The model reminder uses the current execution-time timezone; missing canonical
sources and legacy unbound hosts cannot falsely claim a published native card.

A native answer retains its original repository binding lease through the final
synchronous guard-store save. Account/owner cycles, hidden or ambiguous bindings,
archive/delete and an obsolete nudge/paused stage reject old callbacks; a queued
human answer never retargets the currently selected chat. The choice and outbox
answer commit together with the schedule changes. The prompt update and system
acknowledgment then commit together in a separate SQLite transaction against
the complete canonical history, preserving ordinary messages, reactions and
addresses. A failed acknowledgment can replay only to the original account and
conversation, under a current binding lease, without applying the choice again.
This is an outbox retry, not a cross-store atomic transaction. A failed guard
write leaves the unanswered card and schedules unchanged.

This canonical transcript-only mutation uses a storage-only commit while the
original lease is held: re-entering general-save lease cleanup would deadlock.
Outbox/publication dates use millisecond precision before exact persisted-row
comparison, so JSON/SQLite floating-point round trips do not reject valid entries.
Each new completed assistant prompt counts as one unread arrival; its system
acknowledgment, updates and idempotent replays do not. The host refreshes activity
counts after materialization. A completed read receipt finishes before that later
arrival; new arrivals still revoke queued, uncommitted read callbacks.

Historical and imported activity cards are display-only without buttons or an
indefinite spinner. Closed card summaries and answer confirmations render and
participate in in-chat search in all seven languages; canonical global FTS stores
the English host summary, not every translated variant. Human or unrelated
message bodies are not hidden by imported metadata. Model history excludes only
non-human message IDs in this host's account/conversation-scoped outbox, not
arbitrary imported card hints. Neither publication nor an answer creates a
conversation, tool grant, peer grant or background-memory consent.

The reference's hidden model acknowledgment turn and host reminders are still
separate work, as are group-chat read state and live UI/release validation.
An observation or binding lease fences only mutations through its own repository,
not independent repository instances/processes. Chat and automation timestamps
reside in separate stores, not one cross-store transaction.
A read-state transaction does not provide a cross-process CAS for arbitrary
conversation snapshots or complete account isolation of legacy unbound chats.
