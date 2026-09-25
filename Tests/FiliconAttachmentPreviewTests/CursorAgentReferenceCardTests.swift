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
        try render(language: language, dark: dark, width: 340,
                   id: "bc-" + String(repeating: "a", count: 197), variant: "legacy")
    }

    @Test(arguments: ["maximum-ascii", "maximum-unicode", "reserved"], [260.0, 340.0])
    func opaqueIdentifiersRemainBounded(variant: String, width: Double) throws {
        let id: String
        switch variant {
        case "maximum-ascii": id = String(repeating: "a", count: CursorAgentReference.maximumIDBytes)
        case "maximum-unicode": id = String(repeating: "界", count: CursorAgentReference.maximumIDBytes / 3)
        default: id = "https://example.invalid/中文代理人?任務=設計#進度 %2F"
        }
        try render(language: "zh-Hant", dark: true, width: width, id: id, variant: variant)
    }

    private func render(language: String, dark: Bool, width: Double, id: String, variant: String) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let reference = try CursorAgentReference(bcID: id)
            var message = RoomMessage(groupID: UUID(), senderID: UUID(), text: reference.summary)
            message.cursorAgent = reference
            let host = NSHostingView(rootView: AgentPublishedResponses(publications: [message])
                .padding(16).frame(width: width).background(FiliconTheme.canvas)
                .environment(\.openURL, OpenURLAction { _ in Issue.record("Rendering must not open a website"); return .handled })
                .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            expectNoDifference(size.width, width)
            #expect(size.height > 90 && size.height < 400)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    output.appending(path: "cloud-reference-\(language)-\(dark ? "dark" : "light")-\(variant)-\(Int(width)).png"))
            }
        }
    }
}
