import CustomDump
import Foundation
import Testing
@testable import FiliconAutomations

private let admissionDate = Date(timeIntervalSince1970: 1_800_000_000)
private let admissionSecret = Data("isolated-ingress-fixture".utf8)

private struct AdmissionSecrets: AutomationIngressSecretProvider {
    func secret(for reference: String) async throws -> Data { admissionSecret }
}

/// A handshake, not a timed sleep: only the first caller is suspended.
private actor AdmissionGate {
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
        }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private struct GatedAdmissionSecrets: AutomationIngressSecretProvider {
    let gate: AdmissionGate
    func secret(for reference: String) async throws -> Data {
        await gate.enter()
        return admissionSecret
    }
}

private actor AdmissionSink {
    private(set) var calls = 0
    private var remainingRejections: Int
    init(rejections: Int = 0) { remainingRejections = rejections }
    func accept(_ event: AutomationEvent) -> Bool {
        calls += 1
        guard remainingRejections > 0 else { return true }
        remainingRejections -= 1
        return false
    }
}

private final class AdmissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = admissionDate
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private struct UnusedAdmissionExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        Issue.record("Admission tests must not execute a routine or model")
        return .init(detail: "Unexpected execution")
    }
}

@Suite("Ingress admission and safe retries", .timeLimit(.minutes(1)))
struct IngressAdmissionTests {
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
    private let otherConnector = UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
    private var route: AutomationIngressRoute {
        .init(id: connector, name: "Admission fixture", provider: .generic, secretReference: "fixture")
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "filicon-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func controller(_ root: URL, secrets: any AutomationIngressSecretProvider = AdmissionSecrets(),
                            clock: AdmissionClock = .init(), sink: @escaping AutomationIngressController.EventSink) throws -> AutomationIngressController {
        try .init(stateURL: root.appending(path: "state.json"), auditURL: root.appending(path: "audit.json"),
                  secrets: secrets, now: { clock.now() }, sink: sink)
    }
    private func request(nonce: String = "delivery", date: Date = admissionDate) -> AutomationHTTPRequest {
        let body = Data(#"{"kind":"deploy","externalEventID":"event-1","payload":{}}"#.utf8)
        let timestamp = Int64(date.timeIntervalSince1970)
        return .init(method: "POST", path: route.path, headers: [
            "content-type": "application/json", "x-filicon-timestamp": String(timestamp),
            "x-filicon-nonce": nonce,
            "x-filicon-signature": AutomationIngressSignatureVerifier.genericSignature(
                secret: admissionSecret, timestamp: timestamp, nonce: nonce, body: body)
        ], body: body)
    }
    private func event(_ id: String, connector: UUID? = nil) -> AutomationEvent {
        .init(connectorID: connector ?? self.connector, kind: "deploy", externalEventID: id,
              payloadJSON: Data("{}".utf8), occurredAt: admissionDate)
    }
    /// Make only this isolated fixture's state unwritable; preserve its original bytes.
    private func blockState(_ root: URL) throws {
        let url = root.appending(path: "state.json")
        try FileManager.default.moveItem(at: url, to: root.appending(path: "state.backup"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    private func unblockState(_ root: URL) throws {
        try FileManager.default.removeItem(at: root.appending(path: "state.json")) // Empty fixture directory only.
        try FileManager.default.moveItem(at: root.appending(path: "state.backup"), to: root.appending(path: "state.json"))
    }

    @Test func confirmedQueueRejectionReleasesNonceButAcceptedDeliveryStaysConsumedAfterReopen() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sink = AdmissionSink(rejections: 1)
        let ingress = try controller(root) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        let rejectedStatus = await ingress.process(request()).status
        expectNoDifference(rejectedStatus, 503)
        let retryStatus = await ingress.process(request()).status
        expectNoDifference(retryStatus, 202)
        let replayStatus = await ingress.process(request()).status
        expectNoDifference(replayStatus, 401)
        let reopened = try controller(root) { await sink.accept($0) }
        let reopenedStatus = await reopened.process(request()).status
        expectNoDifference(reopenedStatus, 401)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 2)
        let dispositions = await ingress.audits().map(\.disposition)
        expectNoDifference(dispositions, [.rejected, .accepted, .rejected])
    }

    @Test func failedReservationNeverCallsSinkAndCanRetryAfterStorageRepair() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sink = AdmissionSink()
        let ingress = try controller(root) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        try blockState(root)
        let failedStatus = await ingress.process(request()).status
        expectNoDifference(failedStatus, 500)
        let callsBeforeRepair = await sink.calls
        expectNoDifference(callsBeforeRepair, 0)
        try unblockState(root)
        let retryStatus = await ingress.process(request()).status
        expectNoDifference(retryStatus, 202)
        let callsAfterRepair = await sink.calls
        expectNoDifference(callsAfterRepair, 1)
    }

    @Test func failedReleasePersistsReplayProtectionAndFailsClosed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AdmissionGate(), sink = AdmissionSink(rejections: 1)
        let ingress = try controller(root) { event in
            await gate.enter()
            return await sink.accept(event)
        }
        try await ingress.saveRoute(route)
        let first = Task { await ingress.process(request()) }
        await gate.waitUntilEntered()
        do { try blockState(root) } catch { await gate.release(); _ = await first.value; throw error }
        await gate.release()
        let failedStatus = await first.value.status
        expectNoDifference(failedStatus, 500)
        let replayStatus = await ingress.process(request()).status
        expectNoDifference(replayStatus, 401)
        try unblockState(root)
        let reopened = try controller(root) { await sink.accept($0) }
        let reopenedStatus = await reopened.process(request()).status
        expectNoDifference(reopenedStatus, 401)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 1)
    }

    @Test func auditFailureAfterHandoffDoesNotReleaseNonce() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sink = AdmissionSink()
        let ingress = try controller(root) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        try FileManager.default.createDirectory(at: root.appending(path: "audit.json"), withIntermediateDirectories: false)
        let failedStatus = await ingress.process(request()).status
        expectNoDifference(failedStatus, 500)
        let replayStatus = await ingress.process(request()).status
        expectNoDifference(replayStatus, 401)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 1)
        let auditCount = await ingress.audits().count
        expectNoDifference(auditCount, 0)
    }

    @Test(arguments: ["disable", "remove", "rotate", "provider", "disable-enable", "remove-add", "stop", "rebind"])
    func routeAndListenerChangesInvalidateRequestsWaitingForSecrets(_ mutation: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AdmissionGate(), sink = AdmissionSink()
        let ingress = try controller(root, secrets: GatedAdmissionSecrets(gate: gate)) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        let first = Task { await ingress.process(request()) }
        await gate.waitUntilEntered()
        do {
            var changed = route
            switch mutation {
            case "disable", "disable-enable":
                changed.enabled = false; try await ingress.saveRoute(changed)
                if mutation == "disable-enable" { try await ingress.saveRoute(route) }
            case "remove", "remove-add":
                try await ingress.removeRoute(id: route.id)
                if mutation == "remove-add" { try await ingress.saveRoute(route) }
            case "rotate": changed.secretReference = "replacement"; try await ingress.saveRoute(changed)
            case "provider": changed.provider = .slack; try await ingress.saveRoute(changed)
            case "rebind": try await ingress.start()
            default: try await ingress.stop()
            }
        } catch { await gate.release(); _ = await first.value; throw error }
        await gate.release()
        let staleStatus = await first.value.status
        expectNoDifference(staleStatus, 404)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 0)
        if mutation == "rebind" { try await ingress.stop() }
        if mutation == "disable-enable" || mutation == "remove-add" {
            let freshStatus = await ingress.process(request()).status
            expectNoDifference(freshStatus, 202)
        }
    }

    @Test func bufferedOldListenerRequestsAreRejectedBeforeSecretLookup() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sink = AdmissionSink()
        let ingress = try controller(root) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        try await ingress.stop()
        let staleStatus = await ingress.process(request(), expectedGeneration: 0).status
        expectNoDifference(staleStatus, 404)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 0)
        let state = await ingress.status().state
        expectNoDifference(state, .stopped)
    }

    @Test func unrelatedRouteEditDoesNotInvalidateRequest() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AdmissionGate(), sink = AdmissionSink()
        let ingress = try controller(root, secrets: GatedAdmissionSecrets(gate: gate)) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        let first = Task { await ingress.process(request()) }
        await gate.waitUntilEntered()
        do {
            try await ingress.saveRoute(.init(id: otherConnector, name: "Unrelated", provider: .generic, secretReference: "other"))
        } catch { await gate.release(); _ = await first.value; throw error }
        await gate.release()
        let status = await first.value.status
        expectNoDifference(status, 202)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 1)
    }

    @Test func stoppingAfterHandoffDoesNotPretendToRetractAcceptedWork() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AdmissionGate(), sink = AdmissionSink()
        let ingress = try controller(root) { event in
            await gate.enter()
            return await sink.accept(event)
        }
        try await ingress.saveRoute(route)
        let first = Task { await ingress.process(request()) }
        await gate.waitUntilEntered()
        do { try await ingress.stop() } catch { await gate.release(); _ = await first.value; throw error }
        await gate.release()
        let acceptedStatus = await first.value.status
        expectNoDifference(acceptedStatus, 202)
        let reopened = try controller(root) { await sink.accept($0) }
        let replayStatus = await reopened.process(request()).status
        expectNoDifference(replayStatus, 401)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 1)
    }

    @Test(arguments: [false, true])
    func failedRouteEditsDoNotChangeRuntimeAuthority(_ remove: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ingress = try controller(root) { _ in true }
        try await ingress.saveRoute(route)
        try blockState(root)
        do {
            if remove { try await ingress.removeRoute(id: route.id) }
            else { var changed = route; changed.enabled = false; try await ingress.saveRoute(changed) }
            Issue.record("Expected persistence failure")
        } catch { #expect(error is AutomationIngressError) }
        let routes = await ingress.routes()
        expectNoDifference(routes, [route])
        try unblockState(root)
        let retryStatus = await ingress.process(request()).status
        expectNoDifference(retryStatus, 202)
    }

    @Test func freshnessIsCheckedAfterSecretLookupNotBeforeIt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AdmissionGate(), sink = AdmissionSink(), clock = AdmissionClock()
        let ingress = try controller(root, secrets: GatedAdmissionSecrets(gate: gate), clock: clock) { await sink.accept($0) }
        try await ingress.saveRoute(route)
        let first = Task { await ingress.process(request()) }
        await gate.waitUntilEntered()
        clock.advance(301)
        await gate.release()
        let staleStatus = await first.value.status
        expectNoDifference(staleStatus, 401)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 0)
        let freshStatus = await ingress.process(request(date: clock.now())).status
        expectNoDifference(freshStatus, 202)
    }

    @Test func pendingNonceDoesNotExpireDuringHandoffAndCompletionRefreshesReplayWindow() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AdmissionGate(), sink = AdmissionSink(), clock = AdmissionClock()
        let ingress = try controller(root, clock: clock) { event in
            await gate.enter()
            return await sink.accept(event)
        }
        try await ingress.saveRoute(route)
        let first = Task { await ingress.process(request()) }
        await gate.waitUntilEntered()
        clock.advance(301)
        let concurrent = await ingress.process(request(date: clock.now()))
        await gate.release()
        expectNoDifference(concurrent.status, 401)
        let acceptedStatus = await first.value.status
        expectNoDifference(acceptedStatus, 202)
        let replayStatus = await ingress.process(request(date: clock.now())).status
        expectNoDifference(replayStatus, 401)
        let reopened = try controller(root, clock: clock) { await sink.accept($0) }
        let reopenedStatus = await reopened.process(request(date: clock.now())).status
        expectNoDifference(reopenedStatus, 401)
        let sinkCalls = await sink.calls
        expectNoDifference(sinkCalls, 1)
    }

    @Test func batcherIdentityIncludesConnectorWithoutChangingDuplicateReturnContract() async {
        let batcher = AutomationEventBatcher(debounce: .seconds(3_600)) { _, _ in }
        let firstQueued = await batcher.enqueue(event("same"), automationID: connector)
        expectNoDifference(firstQueued, true)
        let duplicateQueued = await batcher.enqueue(event("same"), automationID: connector)
        expectNoDifference(duplicateQueued, false)
        let otherQueued = await batcher.enqueue(event("same", connector: otherConnector), automationID: connector)
        expectNoDifference(otherQueued, true)
        let queuedCount = await batcher.queuedCount(automationID: connector)
        expectNoDifference(queuedCount, 2)
        await batcher.cancel(automationID: connector)
    }

    @Test func hubAcknowledgesQueuedDuplicateEvenAtCapacityAndFullQueueCanBeRetried() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "routines.json"))
        let hub = AutomationTriggerHub(service: service, executor: UnusedAdmissionExecutor(), debounce: .seconds(3_600))
        let ingress = try controller(root) { await hub.ingest($0) }
        try await ingress.saveRoute(route)
        let acceptedStatus = await ingress.process(request()).status
        expectNoDifference(acceptedStatus, 202)
        let resignedStatus = await ingress.process(request(nonce: "resigned-retry")).status
        expectNoDifference(resignedStatus, 202)
        let otherQueued = await hub.ingest(event("event-1", connector: otherConnector))
        expectNoDifference(otherQueued, true)
        for index in 2..<AutomationService.maximumQueuedEvents {
            #expect(await hub.ingest(event("fill-\(index)")))
        }
        let queuedCount = await hub.queuedCount()
        expectNoDifference(queuedCount, AutomationService.maximumQueuedEvents)
        let duplicateStatus = await ingress.process(request(nonce: "duplicate-at-capacity")).status
        expectNoDifference(duplicateStatus, 202)
        let overflowQueued = await hub.ingest(event("overflow"))
        expectNoDifference(overflowQueued, false)
        // The other route has no queued copy of this event; its failed delivery must remain retryable.
        let second = AutomationIngressRoute(id: UUID(uuidString: "00000000-0000-0000-0000-000000000053")!,
                                            name: "Full queue fixture", provider: .generic, secretReference: "fixture")
        try await ingress.saveRoute(second)
        let signed = request(nonce: "full-retry")
        let full = AutomationHTTPRequest(method: signed.method, path: second.path, headers: signed.headers, body: signed.body)
        let fullStatus = await ingress.process(full).status
        expectNoDifference(fullStatus, 503)
        await hub.cancel()
        let retryStatus = await ingress.process(full).status
        expectNoDifference(retryStatus, 202)
        let remainingCount = await hub.queuedCount()
        expectNoDifference(remainingCount, 1)
        await hub.cancel()
    }
}
