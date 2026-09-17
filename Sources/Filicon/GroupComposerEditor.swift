import AppKit
import SwiftUI

enum GroupComposerCommand { case previous, next, accept, dismiss, submit }

/// A real text editor gives completion access to the caret and IME composition.
/// Key handling is scoped to this editor; no app-wide event monitor is installed.
struct GroupComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    @Binding var composing: Bool
    let placeholder: String
    let onCommand: (GroupComposerCommand, String, NSRange) -> Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = GroupComposerTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: 8)
        editor.font = .systemFont(ofSize: 13)
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("group-message-input")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? GroupComposerTextView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        editor.placeholder = placeholder
        editor.setAccessibilityLabel(placeholder)
        editor.isEditable = isEnabled
        editor.textColor = NSColor(FiliconTheme.textPrimary)
        editor.insertionPointColor = NSColor(FiliconTheme.textPrimary)
        editor.onCommand = onCommand
        editor.onFocusChange = context.coordinator.focusChanged
        // Never replace marked text or reposition the caret while an IME is active.
        if !editor.hasMarkedText() {
            if editor.string != text { editor.string = text }
            if selection.location <= editor.string.utf16.count,
               selection.length <= editor.string.utf16.count - selection.location,
               editor.selectedRange() != selection {
                editor.setSelectedRange(selection)
                editor.scrollRangeToVisible(selection)
            }
        }
        if focused, editor.window?.firstResponder !== editor { editor.window?.makeFirstResponder(editor) }
        editor.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let measured = NSAttributedString(string: text + " ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            .boundingRect(with: NSSize(width: max(1, width - 12), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: min(108, max(33, ceil(measured.height) + 16)))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GroupComposerEditor
        var updating = false
        init(parent: GroupComposerEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) { synchronize(notification) }
        func textViewDidChangeSelection(_ notification: Notification) { synchronize(notification) }

        private func synchronize(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
            parent.composing = editor.hasMarkedText()
        }

        func focusChanged(_ value: Bool) {
            guard !updating else { return }
            parent.focused = value
        }
    }
}

final class GroupComposerTextView: NSTextView {
    var placeholder = ""
    var onCommand: ((GroupComposerCommand, String, NSRange) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        // Let the input method consume arrows/Return/Escape while choosing text.
        guard !hasMarkedText(), let command = Self.command(for: event),
              onCommand?(command, string, selectedRange()) == true else {
            super.keyDown(with: event)
            return
        }
    }

    static func command(for event: NSEvent) -> GroupComposerCommand? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 36, 76: return modifiers.contains(.option) || modifiers.contains(.control) ? nil : .submit
        case 48: return modifiers.isEmpty ? .accept : nil
        case 53: return modifiers.isEmpty ? .dismiss : nil
        case 125: return modifiers.isEmpty ? .next : nil
        case 126: return modifiers.isEmpty ? .previous : nil
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(
                in: NSRect(x: 0, y: textContainerInset.height, width: bounds.width, height: bounds.height),
                withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor(FiliconTheme.textTertiary)]
            )
        }
    }
}
