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

The automation guard's canonical unread counter, group-chat read state, chat
widgets/host reminders and live UI/release validation remain separate. Chat and
automation timestamps reside in separate stores, not one cross-store transaction.
A read-state transaction does not provide a cross-process CAS for arbitrary
conversation snapshots or complete account isolation of legacy unbound chats.
