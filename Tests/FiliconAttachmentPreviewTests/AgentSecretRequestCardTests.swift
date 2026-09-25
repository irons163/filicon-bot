import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain
@testable import Filicon

@MainActor @Suite("Secure credential card", .timeLimit(.minutes(1)))
struct AgentSecretRequestCardTests {
    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func rendersSavedPendingRequestAsUnavailable(language: String) async throws {
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let request = try AgentSecretRequest.parse(Data(#"{"label":"Bot token","connector":"slack","field":"token"}"#.utf8))
        let direct = DirectSecretRequest(requestID: id, request: request,
            binding: .init(accountID: "local", agentID: id), conversationID: id, connectionID: id)
        let card = TranscriptCard(id: id, lifecycle: .waiting,
            payload: .secretRequest(.init(requestID: id.uuidString, service: "slack", directRequest: direct)))
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let presentation = TranscriptCardPresenter.presentation(for: card)
                if language != "en" {
                    #expect(presentation.subtitle != "This credential request is no longer available.")
                }
                let host = NSHostingView(rootView: TranscriptCardRow(card: card) { _ in
                    Issue.record("Saved credential cards must not perform actions")
                }.padding(16).frame(width: 380).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(size.height > 80 && size.height < 450)
                host.frame = .init(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appending(path: "secret-history-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    private func receipt() throws -> AgentSecretReceipt {
        try JSONDecoder().decode(AgentSecretReceipt.self,
            from: Data(#"{"requestID":"00000000-0000-0000-0000-000000000004"}"#.utf8))
    }

    @Test func clearsBeforeWriteAndAcknowledgesOnlyOnce() async throws {
        let receipt = try receipt()
        var writes = 0
        var closes = 0
        var receipts: [AgentSecretReceipt] = []
        var model: AgentSecretRequestCardModel!
        model = .init(label: "Bot token", destinationName: "slack · Fixture", submit: { value in
            expectNoDifference(model.draft, "")
            expectNoDifference(model.status, .submitting)
            expectNoDifference(String(describing: value), "<redacted credential>")
            writes += 1
            return receipt
        }, close: { closes += 1 }, didStore: { receipts.append($0) })
        model.draft = "FAKE-test-only"
        #expect(!String(customDumping: model).contains("FAKE-test-only"))
        await model.submitButtonTapped()
        await model.submitButtonTapped()
        expectNoDifference(model.status, .stored)
        expectNoDifference(model.draft, "")
        expectNoDifference(writes, 1)
        expectNoDifference(closes, 1)
        expectNoDifference(receipts, [receipt])
        model.invalidate()
        expectNoDifference(model.status, .stored)
    }

    @Test func invalidAndFailedInputRequireReentry() async throws {
        let receipt = try receipt()
        var writes = 0
        let model = AgentSecretRequestCardModel(label: "Token", destinationName: "Fixture", submit: { _ in
            writes += 1
            if writes == 1 { throw AgentSecretSubmissionError.writeFailed }
            return receipt
        }, close: {}, didStore: { _ in })
        model.draft = "\n"
        await model.submitButtonTapped()
        expectNoDifference(model.status, .invalidValue)
        expectNoDifference(model.draft, "")
        expectNoDifference(writes, 0)
        model.draft = "FAKE-test-only"
        await model.submitButtonTapped()
        expectNoDifference(model.status, .writeFailed)
        expectNoDifference(model.draft, "")
        #expect(model.canEdit)
        model.draft = "FAKE-test-only"
        await model.submitButtonTapped()
        expectNoDifference(model.status, .stored)
    }

    @Test func unknownErrorDoesNotReachUI() async {
        var closes = 0
        let model = AgentSecretRequestCardModel(label: "Token", destinationName: "Fixture", submit: { _ in
            throw NSError(domain: "FAKE-SECRET", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAKE-SECRET"])
        }, close: { closes += 1 }, didStore: { _ in Issue.record("Unexpected receipt") })
        model.draft = "FAKE-SECRET"
        await model.submitButtonTapped()
        expectNoDifference(model.status, .unavailable)
        expectNoDifference(model.draft, "")
        expectNoDifference(closes, 1)
        #expect(!model.canEdit)
    }

    @Test(arguments: [false, true]) func dismissalFencesLateCompletion(cancelTask: Bool) async throws {
        let receipt = try receipt()
        var continuation: CheckedContinuation<AgentSecretReceipt, Never>?
        var closes = 0
        var delivered = 0
        let model = AgentSecretRequestCardModel(label: "Token", destinationName: "Fixture", submit: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, close: { closes += 1 }, didStore: { _ in delivered += 1 })
        model.draft = "FAKE-test-only"
        let task = Task { await model.submitButtonTapped() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        if cancelTask { task.cancel() } else { model.invalidate() }
        expectNoDifference(model.draft, "")
        pending.resume(returning: receipt)
        await task.value
        expectNoDifference(model.status, .cancelled)
        expectNoDifference(delivered, 0)
        expectNoDifference(closes, 1)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func rendersReceiptRetryWithoutInput(language: String) async throws {
        let receipt = try receipt()
        let model = AgentSecretRequestCardModel(label: "Bot token", destinationName: "slack · Fixture",
            submit: { _ in receipt }, close: {}, didStore: { _ in },
            complete: { _ in throw AgentSecretSubmissionError.unavailable })
        model.draft = "FAKE-ONLY"
        await model.submitButtonTapped()
        expectNoDifference(model.status, .receiptFailed)
        expectNoDifference(model.draft, "")
        #expect(!model.canEdit)
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let host = NSHostingView(rootView: AgentSecretRequestCard(model: model)
                    .padding(16).frame(width: 380).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(size.height > 100 && size.height < 650)
                host.frame = .init(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appending(path: "secret-retry-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func rendersMaskedCard(language: String) async throws {
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let model = AgentSecretRequestCardModel(label: "Bot token", destinationName: "slack · Fixture",
                    submit: { _ in throw AgentSecretSubmissionError.unavailable }, close: {}, didStore: { _ in })
                model.draft = "FAKE-NOT-A-REAL-KEY"
                if language != "en" {
                    #expect(FiliconLocalization.string("Secure credential request") != "Secure credential request")
                }
                let host = NSHostingView(rootView: AgentSecretRequestCard(model: model)
                    .padding(16).frame(width: 380).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(size.height > 100 && size.height < 650)
                host.frame = .init(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appending(path: "secret-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
