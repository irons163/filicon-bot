# FiliconSettings integration notes

`FiliconSettings` is UI-independent. The macOS app can create one `SettingsStore`
under Application Support and bind the returned `FiliconSettings` snapshot to its
observable app model.

- Use `SettingsStore.update` for mutations; it normalizes and atomically replaces
  the JSON file with owner-only (`0600`) permissions.
- Call `scopeToAccount(_:)` after account resolution. The first association keeps
  imported preferences; a later account change clears provider/model and local-tool
  permission choices while retaining per-account usage history.
- Resolve a stored provider/model through `ModelSelectionResolver` using the live
  provider catalog. `.providerDefault` never crosses providers; `.firstAvailable`
  does so only when explicitly selected.
- Translate `FiliconSettings.UpdateTrack` to `FiliconUpdater.UpdateChannel` by raw
  value at the app boundary. Disabled tracks are coerced to stable before persistence.
- `timeZoneIdentifier == nil` means the current macOS system time zone. Non-nil
  values are guaranteed to be in `TimeZone.knownTimeZoneIdentifiers`.

For windows, construct `WindowStateStore` with an injected screen work-area provider.
At launch call `launchPlacement()`. On normal move/resize, maximize/unmaximize, and
close, call `record(_:)` with the current `WindowSnapshot`. Full-screen snapshots are
ignored so full-screen geometry never overwrites the last normal bounds. The geometry
resolver enforces 512×520 minimum size, 100×40 persisted-display visibility, a
1040×760 fallback, and clamps state from a removed display onto the primary work area.
