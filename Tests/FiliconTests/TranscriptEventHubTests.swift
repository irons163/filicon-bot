import XCTest
import FiliconDomain
import FiliconPersistence

final class TranscriptEventHubTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func message(_ text: String, id: UUID = UUID(), attachments: [AttachmentMetadata] = []) -> ChatMessage {
        ChatMessage(id: id, role: .user, text: text, createdAt: Date(timeIntervalSince1970: 123), attachments: attachments)
    }

    func testAppendUpdateRemoveClearAreOrderedAndObservable() async throws {
        let hub = try TranscriptEventHub(conversationID: UUID(), replicaDirectoryURL: directory())
        let subscription = await hub.subscribe()
        var iterator = subscription.events.makeAsyncIterator()
        let id = UUID()

        let appended = try await hub.append(message("one", id: id))
        let updated = try await hub.update(message("two", id: id))
        let removed = try await hub.remove(messageID: id)
        let cleared = try await hub.clear()

        XCTAssertEqual([appended.sequence, updated.sequence, removed.sequence, cleared.sequence], [1, 2, 3, 4])
        let observed = [try await iterator.next()?.id, try await iterator.next()?.id, try await iterator.next()?.id, try await iterator.next()?.id]
        XCTAssertEqual(observed, [appended.id, updated.id, removed.id, cleared.id])
        let snapshot = await hub.snapshot()
        XCTAssertEqual(snapshot.fence.throughSequence, 4)
        XCTAssertTrue(snapshot.messages.isEmpty)
    }

    func testTransactionIsAllOrNothingBeforeJournal() async throws {
        let url = try directory()
        let conversationID = UUID()
        let hub = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let id = UUID()
        await XCTAssertThrowsErrorAsync {
            _ = try await hub.transact([.append(self.message("ok", id: id)), .remove(messageID: UUID())])
        }
        let liveSnapshot = await hub.snapshot()
        XCTAssertTrue(liveSnapshot.messages.isEmpty)

        let reopened = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let reopenedSnapshot = await reopened.snapshot()
        XCTAssertTrue(reopenedSnapshot.messages.isEmpty)
    }

    func testReopenRestoresMessagesAndStartsNewGeneration() async throws {
        let url = try directory()
        let conversationID = UUID()
        let firstGeneration = UUID()
        let hub = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url, generation: firstGeneration)
        _ = try await hub.append(message("durable"))

        let secondGeneration = UUID()
        let reopened = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url, generation: secondGeneration)
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.messages.map(\.text), ["durable"])
        XCTAssertEqual(snapshot.fence, TranscriptFence(generation: secondGeneration, throughSequence: 0))
    }

    func testReopenAfterClearAcceptsEmptyCheckpointAndJournal() async throws {
        let url = try directory()
        let conversationID = UUID()
        let hub = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        _ = try await hub.append(message("temporary"))
        _ = try await hub.clear()

        let reopened = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let snapshot = await reopened.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertEqual(snapshot.fence.throughSequence, 0)
    }

    func testCrashAfterJournalReplaysExactlyOnce() async throws {
        let url = try directory()
        let conversationID = UUID()
        let message = message("journal")
        let failing = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url, faultAt: .afterJournal)
        await XCTAssertThrowsErrorAsync { _ = try await failing.append(message) }
        let failedLiveSnapshot = await failing.snapshot()
        XCTAssertTrue(failedLiveSnapshot.messages.isEmpty)

        let recovered = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let recoveredMessages = await recovered.snapshot().messages
        XCTAssertEqual(recoveredMessages, [message])
        let reopenedAgain = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let twiceReopenedMessages = await reopenedAgain.snapshot().messages
        XCTAssertEqual(twiceReopenedMessages, [message])
    }

    func testCrashAfterCheckpointDoesNotDoubleApplyJournal() async throws {
        let url = try directory()
        let conversationID = UUID()
        let message = message("checkpoint")
        let failing = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url, faultAt: .afterCheckpoint)
        await XCTAssertThrowsErrorAsync { _ = try await failing.append(message) }

        let recovered = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let recoveredMessages = await recovered.snapshot().messages
        XCTAssertEqual(recoveredMessages, [message])
    }

    func testAttachmentAssociationSurvivesReplay() async throws {
        let url = try directory()
        let conversationID = UUID()
        let attachment = AttachmentMetadata(id: "sha256", filename: "note.txt", mimeType: "text/plain", byteCount: 4, kind: .document, createdAt: Date(timeIntervalSince1970: 42))
        let value = message("attached", attachments: [attachment])
        let hub = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        _ = try await hub.append(value)

        let reopened = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: url)
        let reopenedAttachments = await reopened.snapshot().messages.first?.attachments
        XCTAssertEqual(reopenedAttachments, [attachment])
    }

    func testForeignStaleAndGapEventsFailClosed() async throws {
        let conversationID = UUID()
        let generation = UUID()
        let hub = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: directory(), generation: generation)
        let fence = TranscriptFence(generation: generation, throughSequence: 2)
        let key = await hub.snapshot().replicaKey
        let validMutations = [TranscriptMutation.append(message("x"))]

        await XCTAssertThrowsErrorAsync { try await hub.validate(TranscriptEvent(conversationID: UUID(), replicaKey: key, generation: generation, sequence: 3, mutations: validMutations), after: fence) }
        await XCTAssertThrowsErrorAsync { try await hub.validate(TranscriptEvent(conversationID: conversationID, replicaKey: "foreign", generation: generation, sequence: 3, mutations: validMutations), after: fence) }
        await XCTAssertThrowsErrorAsync { try await hub.validate(TranscriptEvent(conversationID: conversationID, replicaKey: key, generation: UUID(), sequence: 3, mutations: validMutations), after: fence) }
        await XCTAssertThrowsErrorAsync { try await hub.validate(TranscriptEvent(conversationID: conversationID, replicaKey: key, generation: generation, sequence: 2, mutations: validMutations), after: fence) }
        await XCTAssertThrowsErrorAsync { try await hub.validate(TranscriptEvent(conversationID: conversationID, replicaKey: key, generation: generation, sequence: 4, mutations: validMutations), after: fence) }
        await XCTAssertThrowsErrorAsync { try await hub.validate(TranscriptEvent(conversationID: conversationID, replicaKey: key, generation: generation, sequence: 3, mutations: []), after: fence) }
    }

    func testBoundedSubscriberOverflowIsExplicit() async throws {
        let hub = try TranscriptEventHub(conversationID: UUID(), replicaDirectoryURL: directory(), subscriberBufferSize: 1)
        let subscription = await hub.subscribe()
        _ = try await hub.append(message("one"))
        _ = try await hub.append(message("two"))

        var iterator = subscription.events.makeAsyncIterator()
        let retained = try await iterator.next()
        XCTAssertEqual(retained?.sequence, 2)
        await XCTAssertThrowsErrorAsync { try await iterator.next() }
    }

    func testMalformedAndForeignDurableFilesFailClosed() throws {
        let malformed = try directory()
        try Data("not-json".utf8).write(to: malformed.appendingPathComponent("transcript-checkpoint.json"))
        XCTAssertThrowsError(try TranscriptEventHub(conversationID: UUID(), replicaDirectoryURL: malformed))

        let foreign = try directory()
        let firstID = UUID()
        _ = try TranscriptEventHub(conversationID: firstID, replicaDirectoryURL: foreign)
        let checkpoint = "{\"conversationID\":\"\(firstID.uuidString)\",\"formatVersion\":1,\"messages\":[],\"replicaKey\":\"conversation:\(firstID.uuidString.lowercased())\",\"throughSequence\":0}"
        try Data(checkpoint.utf8).write(to: foreign.appendingPathComponent("transcript-checkpoint.json"), options: .atomic)
        XCTAssertThrowsError(try TranscriptEventHub(conversationID: UUID(), replicaDirectoryURL: foreign))
    }

    func testTurnMemoryIsBoundedAndSnapshotHydratesDeterministically() async throws {
        let conversationID = UUID()
        let buffer = try TurnMemoryBuffer(conversationID: conversationID, capacity: 2)
        for index in 1...3 {
            try await buffer.record(TurnMemoryExchange(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
                conversationID: conversationID,
                occurredAt: Date(timeIntervalSince1970: Double(index)),
                user: "u\(index)", assistant: "a\(index)"
            ))
        }
        let boundedUsers = await buffer.snapshot().exchanges.map(\.user)
        XCTAssertEqual(boundedUsers, ["u2", "u3"])
        let data = try await buffer.snapshotData()
        let hydrated = try TurnMemoryBuffer.hydrate(data)
        let hydratedSnapshot = await hydrated.snapshot()
        let originalSnapshot = await buffer.snapshot()
        XCTAssertEqual(hydratedSnapshot, originalSnapshot)
        let secondData = try await hydrated.snapshotData()
        XCTAssertEqual(secondData, data)
    }

    func testTurnMemoryRejectsForeignBlankDuplicateAndInvalidHydration() async throws {
        let conversationID = UUID()
        let buffer = try TurnMemoryBuffer(conversationID: conversationID, capacity: 2)
        let value = TurnMemoryExchange(conversationID: conversationID, occurredAt: .distantPast, user: "u", assistant: "a", attachmentIDs: ["blob"])
        try await buffer.record(value)
        await XCTAssertThrowsErrorAsync { try await buffer.record(value) }
        await XCTAssertThrowsErrorAsync {
            try await buffer.record(TurnMemoryExchange(conversationID: UUID(), occurredAt: .distantPast, user: "u", assistant: "a"))
        }
        await XCTAssertThrowsErrorAsync {
            try await buffer.record(TurnMemoryExchange(conversationID: conversationID, occurredAt: .distantPast, user: " ", assistant: "a"))
        }
        XCTAssertThrowsError(try TurnMemoryBuffer.hydrate(Data()))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
