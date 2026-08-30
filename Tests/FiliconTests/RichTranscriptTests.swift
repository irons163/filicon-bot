import Foundation
import Testing
import FiliconDomain
import FiliconPersistence
import CSQLite

private func richTranscriptTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func richTranscriptSQLiteRoundTripPreservesEveryMessageField() async throws {
    let directory = try richTranscriptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let replyTarget = ChatMessage(role: .user, text: "Inspect **this**")
    let tool = ToolActivity(
        id: "call-1",
        name: "workspace.read",
        argumentsJSON: #"{"path":"README.md"}"#,
        status: .succeeded,
        result: "contents"
    )
    let response = ChatMessage(
        role: .assistant,
        text: "Done",
        deliveryStatus: .failed,
        deliveryError: "connection reset",
        reasoningText: "I should inspect the file.",
        toolActivities: [tool],
        transcriptCards: [TranscriptCard(
            lifecycle: .waiting,
            payload: .secretRequest(.init(requestID: "credential-1", service: "GitHub", account: "octocat", scope: "repo")),
            actions: [.init(id: "provide", label: "Provide", intent: .provideSecret(requestID: "credential-1"))]
        )],
        replyToMessageID: replyTarget.id,
        reactions: [.init(emoji: "👍", actorID: "local-user"), .init(emoji: "👍", actorID: "agent-1")]
    )
    let expected = Conversation(title: "Rich", messages: [replyTarget, response])
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    try await repository.save([expected])

    let loaded = try #require(try await repository.load().first)
    #expect(loaded.messages.map(\.id) == expected.messages.map(\.id))
    #expect(loaded.messages.map(\.text) == expected.messages.map(\.text))
    #expect(loaded.messages[1].deliveryStatus == .failed)
    #expect(loaded.messages[1].deliveryError == "connection reset")
    #expect(loaded.messages[1].reasoningText == "I should inspect the file.")
    #expect(loaded.messages[1].toolActivities == [tool])
    #expect(loaded.messages[1].transcriptCards == response.transcriptCards)
    #expect(loaded.messages[1].replyToMessageID == replyTarget.id)
    #expect(loaded.messages[1].reactions == response.reactions)
}

@Test func versionTwoDatabaseMigratesAtomicallyWithBackwardDefaults() async throws {
    let directory = try richTranscriptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    guard let database else { return }
    let conversationID = UUID().uuidString
    let messageID = UUID().uuidString
    let sql = """
    PRAGMA foreign_keys=ON;
    CREATE TABLE schema_version(singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL);
    INSERT INTO schema_version VALUES(1,2);
    CREATE TABLE conversations(id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, provider_id TEXT NOT NULL, model_id TEXT NOT NULL, updated_at REAL NOT NULL) STRICT;
    CREATE TABLE messages(id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('system','user','assistant','tool')), text TEXT NOT NULL, created_at REAL NOT NULL, attachments_json TEXT NOT NULL DEFAULT '[]', UNIQUE(conversation_id,ordinal)) STRICT;
    CREATE VIRTUAL TABLE conversation_search USING fts5(conversation_id UNINDEXED, content, tokenize='unicode61');
    INSERT INTO conversations VALUES('\(conversationID)','Legacy','fake','fake-stream',1000);
    INSERT INTO messages VALUES('\(messageID)','\(conversationID)',0,'assistant','legacy response',1000,'[]');
    """
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    let repository = try ConversationRepository(databaseURL: url)
    #expect(try await repository.schemaVersion() == ConversationRepository.currentSchemaVersion)
    let message = try #require(try await repository.load().first?.messages.first)
    #expect(message.deliveryStatus == .succeeded)
    #expect(message.deliveryError == nil)
    #expect(message.reasoningText.isEmpty)
    #expect(message.toolActivities.isEmpty)
    #expect(message.transcriptCards.isEmpty)
    #expect(message.replyToMessageID == nil)
    #expect(message.reactions.isEmpty)
}

@Test func legacyMessageJSONUsesRichTranscriptDefaults() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","role":"assistant","text":"old","createdAt":1000}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))
    #expect(message.deliveryStatus == .succeeded)
    #expect(message.reasoningText.isEmpty)
    #expect(message.toolActivities.isEmpty)
    #expect(message.transcriptCards.isEmpty)
    #expect(message.reactions.isEmpty)
}

@Test func authoritativeTranscriptCardsAreDiscriminatedAndForwardTolerant() throws {
    let fixtures: [TranscriptCardPayload] = [
        .widget(.init(title: "Metrics", body: "Healthy")),
        .draft(.init(draftID: "d1", channel: "email", recipients: ["team@example.com"], subject: "Status", body: "Ready")),
        .autoReview(.init(reviewID: "r1", title: "Review", findings: ["No blocker"])),
        .listener(.init(listenerID: "l1", connector: "Slack", event: "new message")),
        .secretRequest(.init(requestID: "s1", service: "GitHub")),
        .connector(.init(connectorID: "c1", service: "Linear", title: "Create issue")),
        .localToolPermission(.init(requestID: "p1", toolName: "workspace.read", scope: "/workspace")),
        .notice(.init(title: "Notice", message: "Updated")),
        .timeline(.init(eventKind: "automation_started", name: "Bot", channel: "alerts", automation: "Daily")),
        .cloudAgent(.init(agentID: "a1", bcID: "bc-1", threadID: "thread-1", title: "Researcher")),
        .fileOperation(.init(operationID: "f1", operation: "edit", path: "README.md", diff: "+done")),
        .shell(.init(operationID: "sh1", commandSummary: "swift test", exitCode: 0, isBackground: true)),
    ]
    let cards = fixtures.map { TranscriptCard(lifecycle: .running, payload: $0) }
    let encoded = try JSONEncoder().encode(cards)
    let decoded = try JSONDecoder().decode([TranscriptCard].self, from: encoded)
    #expect(decoded == cards)
    #expect(decoded.map(\.payload.type) == ["widget", "draft", "auto_review", "listener", "secret_request", "connector", "local_tool_permission", "notice", "timeline", "cloud_agent", "file_operation", "shell"])

    let unknown = #"{"id":"00000000-0000-0000-0000-000000000001","schemaVersion":99,"type":"future_card","lifecycle":"teleporting","createdAt":0,"updatedAt":0,"payload":{"title":"Future","api_token":"must-not-survive"},"actions":[{"id":"go","label":"Go","role":"normal","intent":{"type":"future_execute","payload":{"command":"rm","password":"must-not-survive"}}}]}"#
    let future = try JSONDecoder().decode(TranscriptCard.self, from: Data(unknown.utf8))
    #expect(future.payload.type == "future_card")
    #expect(future.lifecycle.rawValue == "teleporting")
    guard case .unknown(_, let safePayload) = future.payload else { Issue.record("Expected unknown payload"); return }
    guard case .object(let object) = safePayload else { Issue.record("Expected object"); return }
    #expect(object["api_token"] == .string("[REDACTED]"))
    #expect(future.actions.first?.intent.isRendererSafe == false)
    let reencoded = String(decoding: try JSONEncoder().encode(future), as: UTF8.self)
    #expect(reencoded.contains("future_card"))
    #expect(!reencoded.contains("must-not-survive"))
    let message = ChatMessage(role: .assistant, text: "future", transcriptCards: [future])
    let messageRoundTrip = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(messageRoundTrip.text == "future")
    #expect(messageRoundTrip.transcriptCards.first?.payload.type == "future_card")
}

@Test func transcriptCardSQLiteMigrationAndSecretBoundary() async throws {
    let directory = try richTranscriptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let repository = try ConversationRepository(databaseURL: url)
    let card = TranscriptCard(
        lifecycle: .pending,
        payload: .unknown(type: "vendor_extension", payload: .object([
            "summary": .string("safe"),
            "client_secret": .string("plaintext-must-not-persist"),
        ]))
    )
    let conversation = Conversation(messages: [ChatMessage(role: .assistant, text: "", transcriptCards: [card])])
    try await repository.save([conversation])
    #expect(try await repository.schemaVersion() == ConversationRepository.currentSchemaVersion)
    let loaded = try #require(try await repository.load().first?.messages.first?.transcriptCards.first)
    guard case .unknown(_, let payload) = loaded.payload, case .object(let object) = payload else {
        Issue.record("Expected preserved unknown transcript card")
        return
    }
    #expect(object["summary"] == .string("safe"))
    #expect(object["client_secret"] == .string("[REDACTED]"))
    let pageCard = try #require(try await repository.messagePage(conversationID: conversation.id).items.first?.transcriptCards.first)
    #expect(pageCard.payload.type == "vendor_extension")

    var database: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "SELECT transcript_cards_json FROM messages LIMIT 1", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let stored = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
    #expect(stored.contains("[REDACTED]"))
    #expect(!stored.contains("plaintext-must-not-persist"))
}

@Test func transcriptCardActionLifecycleTransitionsAreDurableAndSecretsStayOutOfRows() async throws {
    let directory = try richTranscriptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let literalSecret = "literal-key-that-must-never-enter-the-transcript"
    let cardID = UUID()
    var card = TranscriptCard(
        id: cardID, lifecycle: .running,
        payload: .secretRequest(.init(
            requestID: "request", service: "github", account: "octocat",
            scope: "repo", prompt: "Enter credential"
        )),
        actions: [.init(id: "provide", label: "Provide", intent: .provideSecret(requestID: "request"))]
    )
    var conversation = Conversation(messages: [.init(role: .assistant, text: "", transcriptCards: [card])])
    try await repository.upsert(conversation)

    card.lifecycle = .provided
    card.updatedAt = card.updatedAt.addingTimeInterval(1)
    conversation.messages[0].transcriptCards[0] = card
    try await repository.upsert(conversation)

    let loaded = try #require(try await repository.conversation(id: conversation.id))
    #expect(loaded.messages[0].transcriptCards[0].id == cardID)
    #expect(loaded.messages[0].transcriptCards[0].lifecycle == .provided)
    let encoded = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
    #expect(!encoded.contains(literalSecret))
    #expect(!encoded.contains("secretValue"))
    #expect(!encoded.contains("credentialValue"))

    var database: OpaquePointer?
    let url = directory.appending(path: "chat.sqlite3")
    #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "SELECT transcript_cards_json FROM messages LIMIT 1", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let stored = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
    #expect(stored.contains("provided"))
    #expect(!stored.contains(literalSecret))
}

@Test func inferenceEventsBuildReasoningAndToolActivityRows() throws {
    var message = ChatMessage(role: .assistant, text: "", deliveryStatus: .queued)
    message.consume(.responseStarted(id: "response-1"))
    message.consume(.reasoningDelta("Thinking"))
    message.consume(.toolCallStarted(id: "call-1", name: "workspace.read"))
    message.consume(.toolCallArgumentsDelta(id: "call-1", delta: #"{"path":"README.md"}"#))
    let call = try NormalizedToolCall(id: "call-1", name: "workspace.read", argumentsJSON: Data(#"{"path":"README.md"}"#.utf8))
    message.consume(.toolCallCompleted(call))
    message.consume(.toolResult(.init(callID: "call-1", content: [.text("hello")])))
    message.consume(.textDelta("Answer"))
    message.consume(.completed(.stop))

    #expect(message.deliveryStatus == .succeeded)
    #expect(message.reasoningText == "Thinking")
    #expect(message.text == "Answer")
    #expect(message.toolActivities == [.init(id: "call-1", name: "workspace.read", argumentsJSON: #"{"path":"README.md"}"#, status: .succeeded, result: "hello")])
}

@Test func reactionToggleReplyDeleteAndResendStateStayConsistent() {
    let target = ChatMessage(role: .user, text: "Question")
    var failed = ChatMessage(role: .assistant, text: "partial", deliveryStatus: .failed, deliveryError: "offline", reasoningText: "work", replyToMessageID: target.id)
    var reply = ChatMessage(role: .user, text: "Follow-up", replyToMessageID: failed.id)
    var conversation = Conversation(messages: [target, failed, reply])

    #expect(conversation.toggleReaction(messageID: failed.id, emoji: " 👍 ", actorID: "me") == true)
    #expect(conversation.toggleReaction(messageID: failed.id, emoji: "👍", actorID: "me") == false)
    failed.prepareForResend()
    #expect(failed.deliveryStatus == .queued)
    #expect(failed.text.isEmpty && failed.reasoningText.isEmpty && failed.deliveryError == nil)
    let deleted = conversation.deleteMessage(id: failed.id)
    #expect(deleted)
    reply = conversation.messages[1]
    #expect(reply.replyToMessageID == nil)
}
