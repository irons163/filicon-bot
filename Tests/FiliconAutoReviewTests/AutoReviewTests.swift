import Foundation
import XCTest
import FiliconAutoReview
import FiliconDomain

final class AutoReviewTests: XCTestCase {
    func testInstructionBoundsAreEnforcedOnInitAndDecode() throws {
        let long = String(repeating: "x", count: 1_200)
        let value = AutoReviewInstructions(
            isEnabled: true,
            allowRules: Array(repeating: long, count: 25),
            askRules: Array(repeating: " ask ", count: 23)
        )
        XCTAssertEqual(value.allowRules.count, 20)
        XCTAssertEqual(value.askRules.count, 20)
        XCTAssertEqual(value.allowRules[0].count, 1_000)
        XCTAssertEqual(value.askRules[0], "ask")

        var mutated = value
        mutated.allowRules = Array(repeating: long, count: 30)
        XCTAssertEqual(mutated.allowRules.count, 20)
        XCTAssertEqual(mutated.allowRules[0].count, 1_000)

        let decoded = try JSONDecoder().decode(AutoReviewInstructions.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testAskRuleWinsConflictingAllowRule() async {
        let action = makeAction(summary: "Upload reports to example.com")
        let rules = AutoReviewInstructions(
            isEnabled: true,
            allowRules: ["upload reports to example.com"],
            askRules: ["example.com"]
        )
        let result = await AutoReviewer().evaluate(action, instructions: rules)
        XCTAssertEqual(result.decision, .ask)
        XCTAssertTrue(result.reason.contains("ask rule"))
    }

    func testAllowRuleRequiresWordBoundaries() async {
        let result = await AutoReviewer().evaluate(
            makeAction(summary: "update thread status", risks: [.externalSideEffect]),
            instructions: .init(isEnabled: true, allowRules: ["read"])
        )
        XCTAssertEqual(result.decision, .ask)
    }

    func testDestructiveActionCanNeverBeAutoApproved() async {
        let action = makeAction(summary: "delete cache", risks: [.destructive])
        let result = await AutoReviewer(classifier: AlwaysAllowClassifier()).evaluate(
            action,
            instructions: .init(isEnabled: true, allowRules: ["delete cache"])
        )
        XCTAssertEqual(result.decision, .ask)
        XCTAssertTrue(result.reason.contains("Built-in safety"))
    }

    func testUntrustedClassifierFailsClosed() async {
        let result = await AutoReviewer(classifier: UntrustedAllowClassifier()).evaluate(
            makeAction(summary: "read status"),
            instructions: .init(isEnabled: true, allowRules: ["read status"])
        )
        XCTAssertEqual(result.decision, .ask)
        XCTAssertTrue(result.reason.contains("trusted classifier"))
    }

    func testApprovalResumesWrappedOperationExactlyOnceAndRejectsReplay() async throws {
        let broker = PendingApprovalBroker()
        let counter = ExecutionCounter()
        let wrapped = CountingExecutor(counter: counter)
        let fence = makeFence()
        await broker.activate(fence)
        let executor = reviewing(wrapped, broker: broker, fence: fence)
        let call = try makeCall()

        let task = Task { try await executor.execute(call, context: .init(conversationID: UUID(), runID: fence.runID)) }
        let pending = try await waitForPending(broker)
        try await broker.resolve(reviewID: pending.id, resolution: .approve, fence: fence)
        let result = try await task.value
        XCTAssertEqual(result.callID, call.id)
        let countAfterApproval = await counter.value
        XCTAssertEqual(countAfterApproval, 1)
        do {
            try await broker.resolve(reviewID: pending.id, resolution: .approve, fence: fence)
            XCTFail("replay unexpectedly succeeded")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .replay(pending.id))
        }
        let countAfterReplay = await counter.value
        XCTAssertEqual(countAfterReplay, 1)
    }

    func testMatchingAllowRuleRunsWithoutPendingApproval() async throws {
        let broker = PendingApprovalBroker()
        let counter = ExecutionCounter()
        let fence = makeFence()
        let executor = ReviewingToolExecutor(
            wrapping: CountingExecutor(counter: counter),
            broker: broker,
            instructions: { .init(isEnabled: true, allowRules: ["read status"]) },
            action: { call, _, context in
                .init(
                    summary: "read status",
                    target: .resource(kind: "status", identifier: "local"),
                    risks: [.readOnly],
                    context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue)
                )
            }
        )
        _ = try await executor.execute(
            try makeCall(),
            context: .init(conversationID: UUID(), runID: fence.runID)
        )
        let count = await counter.value
        let pending = await broker.pendingApprovals
        XCTAssertEqual(count, 1)
        XCTAssertTrue(pending.isEmpty)
    }

    func testExecutorRejectsActionForDifferentRunBeforeReviewOrExecution() async throws {
        let broker = PendingApprovalBroker()
        let counter = ExecutionCounter()
        let fence = makeFence()
        let context = ToolContext(conversationID: UUID(), runID: UUID())
        let executor = ReviewingToolExecutor(
            wrapping: CountingExecutor(counter: counter),
            broker: broker,
            instructions: { .init(isEnabled: true, allowRules: ["read status"]) },
            action: { call, _, suppliedContext in
                .init(
                    summary: "read status",
                    target: .resource(kind: "status", identifier: "local"),
                    risks: [.readOnly],
                    context: .init(
                        fence: fence,
                        conversationID: suppliedContext.conversationID,
                        toolCallID: call.id.rawValue
                    )
                )
            }
        )
        do {
            _ = try await executor.execute(try makeCall(), context: context)
            XCTFail("mismatched run reached the wrapped executor")
        } catch let error as ReviewingToolExecutorError {
            XCTAssertEqual(error, .actionContextMismatch)
        }
        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
    }

    func testDenialNeverRunsOperation() async throws {
        let broker = PendingApprovalBroker()
        let counter = ExecutionCounter()
        let fence = makeFence()
        let executor = reviewing(CountingExecutor(counter: counter), broker: broker, fence: fence)
        let task = Task {
            try await executor.execute(
                try makeCall(),
                context: .init(conversationID: UUID(), runID: fence.runID)
            )
        }
        let pending = try await waitForPending(broker)
        try await broker.resolve(reviewID: pending.id, resolution: .deny, fence: fence)
        await assertTask(task, throws: .denied(pending.id))
        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
    }

    func testExpiryNeverRunsOperation() async throws {
        let broker = PendingApprovalBroker()
        let request = PendingApproval(
            id: "expires",
            action: makeAction(summary: "read", fence: makeFence()),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        let task = Task { try await broker.waitForApproval(request) }
        _ = try await waitForPending(broker)
        await broker.expire(now: Date().addingTimeInterval(61))
        await assertVoidTask(task, throws: .expired("expires"))
    }

    func testCancellationRemovesContinuation() async throws {
        let broker = PendingApprovalBroker()
        let request = PendingApproval(
            id: "cancelled",
            action: makeAction(summary: "read", fence: makeFence()),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        let task = Task { try await broker.waitForApproval(request) }
        _ = try await waitForPending(broker)
        task.cancel()
        await assertVoidTask(task, throws: .cancelled("cancelled"))
        let remaining = await broker.pendingApprovals
        XCTAssertTrue(remaining.isEmpty)
    }

    func testGenerationSwitchCancelsOldApproval() async throws {
        let broker = PendingApprovalBroker()
        let old = makeFence(generation: 1)
        let next = ApprovalFence(accountID: old.accountID, agentID: old.agentID, runID: UUID(), generation: 2)
        await broker.activate(old)
        let request = PendingApproval(
            id: "old-generation",
            action: makeAction(summary: "read", fence: old),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        let task = Task { try await broker.waitForApproval(request) }
        _ = try await waitForPending(broker)
        await broker.activate(next)
        await assertVoidTask(task, throws: .cancelled(request.id))
        do {
            try await broker.resolve(reviewID: request.id, resolution: .approve, fence: old)
            XCTFail("old approval replay succeeded")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .replay(request.id))
        }
    }

    func testAccountTransitionRejectsNewRequestsFromOldAccount() async throws {
        let broker = PendingApprovalBroker()
        let old = makeFence()
        await broker.activate(old)
        await broker.transitionAccount(to: "new-account")
        let request = PendingApproval(
            id: "old-account",
            action: makeAction(summary: "read", fence: old),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        do {
            try await broker.waitForApproval(request)
            XCTFail("old account request registered after account transition")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .fenceMismatch(request.id))
        }
        let remaining = await broker.pendingApprovals
        XCTAssertTrue(remaining.isEmpty)
    }

    func testReplayTombstonesAreNotEvicted() async throws {
        let broker = PendingApprovalBroker()
        let fence = makeFence()
        let expiredAt = Date().addingTimeInterval(-1)

        for index in 0..<2_050 {
            let request = PendingApproval(
                id: "completed-\(index)",
                action: makeAction(summary: "read", fence: fence),
                reason: "test",
                expiresAt: expiredAt
            )
            do { try await broker.waitForApproval(request) }
            catch let error as PendingApprovalError { XCTAssertEqual(error, .expired(request.id)) }
        }

        let replay = PendingApproval(
            id: "completed-0",
            action: makeAction(summary: "read", fence: fence),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        do {
            try await broker.waitForApproval(replay)
            XCTFail("evicted approval ID was replayed")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .replay(replay.id))
        }
    }

    func testWrongAccountRunOrGenerationCannotResolve() async throws {
        let broker = PendingApprovalBroker()
        let fence = makeFence()
        await broker.activate(fence)
        let request = PendingApproval(
            id: "fenced",
            action: makeAction(summary: "read", fence: fence),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        let task = Task { try await broker.waitForApproval(request) }
        _ = try await waitForPending(broker)
        let wrong = ApprovalFence(accountID: "other", agentID: fence.agentID, runID: fence.runID, generation: fence.generation)
        do {
            try await broker.resolve(reviewID: request.id, resolution: .approve, fence: wrong)
            XCTFail("wrong fence succeeded")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .fenceMismatch(request.id))
        }
        try await broker.resolve(reviewID: request.id, resolution: .approve, fence: fence)
        try await task.value
    }

    func testConcurrentResolutionHasOneWinner() async throws {
        let broker = PendingApprovalBroker()
        let fence = makeFence()
        let request = PendingApproval(
            id: "race",
            action: makeAction(summary: "read", fence: fence),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        let waiter = Task { try await broker.waitForApproval(request) }
        _ = try await waitForPending(broker)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do { try await broker.resolve(reviewID: request.id, resolution: .approve, fence: fence); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 1)
        try await waiter.value
    }

    func testDuplicateAndStaleIDsAreRejected() async throws {
        let broker = PendingApprovalBroker()
        let fence = makeFence()
        do {
            try await broker.resolve(reviewID: "unknown", resolution: .approve, fence: fence)
            XCTFail("unknown ID succeeded")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .stale("unknown"))
        }

        let request = PendingApproval(
            id: "duplicate",
            action: makeAction(summary: "read", fence: fence),
            reason: "test",
            expiresAt: Date().addingTimeInterval(60)
        )
        let first = Task { try await broker.waitForApproval(request) }
        _ = try await waitForPending(broker)
        do {
            try await broker.waitForApproval(request)
            XCTFail("duplicate ID succeeded")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .duplicate(request.id))
        }
        await broker.cancel(reviewID: request.id, fence: fence)
        await assertVoidTask(first, throws: .cancelled(request.id))
    }

    func testPerAgentPendingLimit() async throws {
        let broker = PendingApprovalBroker(maximumPendingPerAgent: 1)
        let fence = makeFence()
        let first = PendingApproval(id: "first", action: makeAction(summary: "one", fence: fence), reason: "", expiresAt: Date().addingTimeInterval(60))
        let second = PendingApproval(id: "second", action: makeAction(summary: "two", fence: fence), reason: "", expiresAt: Date().addingTimeInterval(60))
        let firstTask = Task { try await broker.waitForApproval(first) }
        _ = try await waitForPending(broker)
        do {
            try await broker.waitForApproval(second)
            XCTFail("pending limit was not enforced")
        } catch let error as PendingApprovalError {
            XCTAssertEqual(error, .pendingLimit(agentID: fence.agentID, maximum: 1))
        }
        await broker.cancel(reviewID: first.id, fence: fence)
        await assertVoidTask(firstTask, throws: .cancelled(first.id))
    }

    func testAtomicStoreUses0600AndMigratesLegacyModeAndKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = Data(#"{"mode":"auto","allow":["read reports"],"block":["private"]}"#.utf8)
        try legacy.write(to: url)

        let store = AtomicAutoReviewInstructionsStore(fileURL: url)
        let migrated = try store.load()
        XCTAssertTrue(migrated.isEnabled)
        XCTAssertEqual(migrated.allowRules, ["read reports"])
        XCTAssertEqual(migrated.askRules, ["private"])
        try store.save(migrated)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let currentJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(currentJSON?["mode"] as? String, "enabled")
        XCTAssertEqual(currentJSON?["isEnabled"] as? Bool, true)

        let disabled = try JSONDecoder().decode(
            AutoReviewInstructions.self,
            from: Data(#"{"mode":"off","allow":["read"]}"#.utf8)
        )
        XCTAssertFalse(disabled.isEnabled)
    }
}

private struct AlwaysAllowClassifier: AutoReviewClassifier {
    func classify(action: AutoReviewAction, instructions: AutoReviewInstructions) async throws -> AutoReviewClassification {
        .init(decision: .allow, reason: "allowed", isTrusted: true)
    }
}

private struct UntrustedAllowClassifier: AutoReviewClassifier {
    func classify(action: AutoReviewAction, instructions: AutoReviewInstructions) async throws -> AutoReviewClassification {
        .init(decision: .allow, reason: "allowed", isTrusted: false)
    }
}

private actor ExecutionCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct CountingExecutor: ToolExecutor {
    let counter: ExecutionCounter
    var descriptor: ToolDescriptor { .init(name: "test__read") }
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await counter.increment()
        return .init(callID: call.id, content: [.text("done")])
    }
}

private func makeFence(generation: UInt64 = 1) -> ApprovalFence {
    .init(accountID: "account", agentID: "agent", runID: UUID(), generation: generation)
}

private func makeAction(
    summary: String,
    risks: Set<AutoReviewRisk> = [.readOnly],
    fence: ApprovalFence = makeFence()
) -> AutoReviewAction {
    .init(
        summary: summary,
        target: .resource(kind: "test", identifier: summary),
        risks: risks,
        context: .init(fence: fence, conversationID: UUID(), toolCallID: "call")
    )
}

private func makeCall() throws -> NormalizedToolCall {
    try .init(id: "call", name: "test__read", argumentsJSON: Data("{}".utf8))
}

private func reviewing(
    _ wrapped: any ToolExecutor,
    broker: PendingApprovalBroker,
    fence: ApprovalFence
) -> ReviewingToolExecutor {
    ReviewingToolExecutor(
        wrapping: wrapped,
        reviewer: AutoReviewer(classifier: UntrustedAllowClassifier()),
        broker: broker,
        instructions: { .init(isEnabled: true, allowRules: ["read"]) },
        action: { call, _, context in
            .init(
                summary: "read",
                target: .resource(kind: "test", identifier: "value"),
                risks: [.readOnly],
                context: .init(fence: fence, conversationID: context.conversationID, toolCallID: call.id.rawValue)
            )
        }
    )
}

private func waitForPending(_ broker: PendingApprovalBroker) async throws -> PendingApproval {
    for _ in 0..<1_000 {
        if let value = await broker.pendingApprovals.first { return value }
        await Task.yield()
    }
    throw NSError(domain: "AutoReviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "approval was not registered"])
}

private func assertVoidTask(
    _ task: Task<Void, Error>,
    throws expected: PendingApprovalError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { try await task.value; XCTFail("task unexpectedly succeeded", file: file, line: line) }
    catch let error as PendingApprovalError { XCTAssertEqual(error, expected, file: file, line: line) }
    catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}

private func assertTask(
    _ task: Task<NormalizedToolResult, Error>,
    throws expected: PendingApprovalError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { _ = try await task.value; XCTFail("task unexpectedly succeeded", file: file, line: line) }
    catch let error as PendingApprovalError { XCTAssertEqual(error, expected, file: file, line: line) }
    catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}
