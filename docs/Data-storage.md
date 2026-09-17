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
