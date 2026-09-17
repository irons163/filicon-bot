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

## Verification

`ConversationDesignTests` covers the responsive breakpoint, draft separation, membership binding, persistence validation, transcript preservation and native SwiftUI rendering. To export review PNGs without changing the user's data:

```sh
FILICON_UI_REVIEW_OUTPUT=/absolute/temp/review-directory \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter ConversationDesignTests
```

The optional render fixture produces all seven interface languages, compact/narrow layouts, light/dark appearances, an empty workspace and a direct chat. The fixture's Chinese message content and agent names intentionally do not change when the interface language changes. These are review renders, not pixel-baseline comparisons or end-to-end provider tests.

Run `python3 scripts/localization_audit.py` and `scripts/package-app.sh` before delivery. Live QA should check the new-group sheet, workspace popover, settings, and reopening the packaged app. Do not seed demo groups into the user's workspace to take screenshots.
