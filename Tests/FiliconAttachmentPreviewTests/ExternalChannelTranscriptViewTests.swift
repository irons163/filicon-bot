import AppKit
import SwiftUI
import Vision
import Foundation
import Testing
import CustomDump
import FiliconDomain
@testable import Filicon

@Suite("External channel transcript native presentation", .timeLimit(.minutes(3)))
@MainActor struct ExternalChannelTranscriptViewTests {
    private func value(status: ExternalChannelTranscriptPublication.Status) -> ExternalChannelTranscriptPublication {
        let id = UUID(uuidString: "39000000-0000-0000-0000-000000000001")!, date = Date(timeIntervalSince1970: 1_900_000_000)
        return .init(deliveryID: id, connectionID: id, owner: .init(accountID: "fixture", agentID: id), route: .directConversation,
            conversationID: id, senderID: id, senderName: "Original member", runID: id, callID: "original-call", replyToMessageID: nil,
            queuedAt: date, kind: .text, text: "Exact original caption", sources: [
                .init(url: "https://never-fetch.invalid/report.png?signature=a%2Bb&literal={0}", alt: "FIRST ORIGINAL DESCRIPTION"),
                .init(url: "file:///never-read/SECOND-UNSENT.png", alt: "END ORIGINAL DESCRIPTION")], files: [
                    .init(digest: String(repeating: "a", count: 64), filename: "report.png", mimeType: "image/png", byteCount: 1024)],
            platform: "slack", channelID: "C_ORIGINAL", threadID: nil,
            delivery: .init(status: status, attemptCount: status == .queued ? 0 : 1, deliveredAt: status == .delivered ? date.addingTimeInterval(1) : nil))
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func statusCardsRenderInSevenLanguagesAtTwoWidthsAndAppearances(language: String) async throws {
        let statuses: [ExternalChannelTranscriptPublication.Status] = [.queued, .sending, .retrying, .delivered, .deadLetter]
        // Independent semantic fixtures: checking a lookup against the same
        // catalog would miss a mistranslation such as Korean "Delivered".
        let expected: [String: [String]] = [
            "en": ["Queued", "Sending…", "Retrying", "Delivered", "Failed"],
            "zh-Hant": ["已排隊", "傳送中…", "重試中", "已送達", "失敗"],
            "zh-Hans": ["已排队", "发送中…", "重试中", "已送达", "失败"],
            "fr": ["En attente", "Envoi en cours…", "Nouvelle tentative en cours", "Livré", "Échec"],
            "es": ["En cola", "Enviando…", "Reintentando", "Entregado", "Fallido"],
            "ja": ["待機中", "送信中…", "再試行中", "配信済み", "失敗"],
            "ko": ["대기열에 있음", "전송 중…", "재시도 중", "전달 완료", "실패"]]
        let labels = try #require(expected[language])
        for dark in [false, true] {
            for width in [280.0, 680.0] {
                for (index, status) in statuses.enumerated() {
                    try await withUIRenderTurn(language: language) {
                        let value = value(status: status)
                        let card = ExternalChannelPublicationCard(publication: value)
                        expectNoDifference(card.status, labels[index])
                        if language != "en" { #expect(l10n("External channel message") != "External channel message") }
                        let host = NSHostingView(rootView: TranscriptCardRow(card: value.transcriptCard) { _ in
                            Issue.record("Delivery history has no generic send/retry authority")
                        }.padding(16).frame(width: width).background(FiliconTheme.canvas)
                            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        let size = host.fittingSize
                        #expect(abs(size.width - width) < 0.5 && size.height > 120 && size.height < 1400)
                        host.frame = .init(origin: .zero, size: size)
                        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                        window.appearance = host.appearance; window.contentView = host
                        defer { window.contentView = nil }
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                        let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
                        let visible = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace } ?? ""
                        #expect(visible.contains("ENDORIGINALDESCRIPTION"), "The final original source description must remain visible: \(visible)")
                        expectNoDifference(value.sources[0].url, "https://never-fetch.invalid/report.png?signature=a%2Bb&literal={0}")
                        if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                            let directory = URL(fileURLWithPath: path)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                                directory.appending(path: "external-channel-\(language)-\(Int(width))-\(dark ? "dark" : "light")-\(status.rawValue).png"))
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: ["externalChannelPublication", "summary", "choice"])
    func decodedDisplayEvidenceNeverGrantsGenericRetryOrDismiss(kind: String) async throws {
        let value = value(status: .deadLetter)
        for intent in [TranscriptCardActionIntent.retry(cardID: value.deliveryID), .dismiss(cardID: value.deliveryID)] {
            var card = value.transcriptCard
            card.payload = .widget(.init(title: "Untrusted imported title", widgetKind: kind, externalPublication: value))
            card.actions = [.init(id: "forged", label: "Retry", intent: intent)]
            expectNoDifference(card.rendererActions, [])
            await #expect(throws: TranscriptCardActionRoutingError.mismatchedTarget) {
                try await TranscriptCardActionRouter().begin(card: card, intent: intent)
            }
        }
        let legacy = try JSONDecoder().decode(WidgetTranscriptCard.self, from: Data(#"{"title":"Old widget","body":"Readable","widgetKind":"summary","facts":{}}"#.utf8))
        #expect(legacy.externalPublication == nil)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [280.0, 680.0])
    func nativeCapturedFilePreviewButtonFitsSevenLanguagesWithoutLinkingUnsentSources(language: String, width: Double) async throws {
        let expected = try #require([
            "en": "Preview attachment", "zh-Hant": "預覽附件", "zh-Hans": "预览附件",
            "fr": "Aperçu de la pièce jointe", "es": "Vista previa del archivo adjunto",
            "ja": "添付ファイルをプレビュー", "ko": "첨부 파일 미리 보기"
        ][language])
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                expectNoDifference(l10n("Preview attachment"), expected)
                let original = value(status: .queued)
                expectNoDifference(original.files.count, 1)
                expectNoDifference(original.sources.count, 2)
                expectNoDifference(original.transcriptCard.rendererActions, [])
                let host = NSHostingView(rootView: TranscriptCardRow(card: original.transcriptCard,
                    onPreviewExternalAttachment: { _ in Issue.record("Rendering must not perform a preview read") }) { _ in
                        Issue.record("A captured preview button never grants retry or send authority")
                    }.padding(16).frame(width: width).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(abs(size.width - width) < 0.5 && size.height > 120 && size.height < 1400)
                host.frame = .init(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance; window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
                let visible = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace } ?? ""
                #expect(visible.contains("ENDORIGINALDESCRIPTION"), "All source metadata must remain visible: \(visible)")
                if language == "en" { #expect(visible.lowercased().contains("previewattachment")) }
                if language == "es" {
                    #expect(visible.lowercased().contains("archivoadjunto"), "The full Spanish preview label must fit: \(visible)")
                }
                if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                        directory.appending(path: "captured-channel-button-\(language)-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
