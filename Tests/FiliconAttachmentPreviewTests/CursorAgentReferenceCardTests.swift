import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
@testable import Filicon

@Suite("Cursor reference card rendering", .timeLimit(.minutes(1)))
@MainActor struct CursorAgentReferenceCardTests {
    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [false, true])
    func cardRendersWithoutNetwork(language: String, dark: Bool) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let reference = try CursorAgentReference(bcID: "bc-" + String(repeating: "a", count: 197))
            var message = RoomMessage(groupID: UUID(), senderID: UUID(), text: reference.summary)
            message.cursorAgent = reference
            let host = NSHostingView(rootView: AgentPublishedResponses(publications: [message])
                .padding(16).frame(width: 340).background(FiliconTheme.canvas)
                .environment(\.openURL, OpenURLAction { _ in Issue.record("Rendering must not open a website"); return .handled })
                .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            expectNoDifference(size.width, 340)
            #expect(size.height > 90 && size.height < 400)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    output.appending(path: "cloud-reference-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
