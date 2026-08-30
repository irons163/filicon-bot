import XCTest
@testable import FiliconAccount

private actor MemorySecrets: AccountSecretStore {
    var values: [String: Data] = [:]
    var deleteFails = false
    var writeDelay: Duration = .zero
    func read(_ key: String) async throws -> Data? { values[key] }
    func write(_ value: Data, for key: String) async throws { try await Task.sleep(for: writeDelay); values[key] = value }
    func delete(_ key: String) async throws { if deleteFails { throw TestError.failed }; values[key] = nil }
    func failDeletion() { deleteFails = true }
    func delayWrites(_ value: Duration) { writeDelay = value }
    func contains(_ key: String) -> Bool { values[key] != nil }
}
private enum TestError: Error { case failed }
private final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock(); private var dates: [Date]
    init(_ dates: [Date]) { self.dates = dates }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return dates.count > 1 ? dates.removeFirst() : dates[0] }
}
private actor Provider: AccountProvider {
    var exchangeDelay: Duration = .zero
    var profileDelay: Duration = .zero
    var refreshedRefreshToken = "new-refresh"
    var exchangeCalls = 0
    func exchange(code: String, redirectURI: URL, verifier: String) async throws -> OAuthTokens {
        exchangeCalls += 1; try await Task.sleep(for: exchangeDelay)
        return OAuthTokens(accessToken: "access-\(code)", refreshToken: "refresh", expiresAt: .now.addingTimeInterval(3600))
    }
    func refresh(refreshToken: String) async throws -> OAuthTokens { OAuthTokens(accessToken: "new", refreshToken: refreshedRefreshToken, expiresAt: .now.addingTimeInterval(3600)) }
    func profile(accessToken: String) async throws -> AccountProfile {
        try await Task.sleep(for: profileDelay)
        return try AccountProfile(id: "user", email: "a@example.test", displayName: " Ada   Lovelace ", avatarURL: URL(string: "https://example.test/a.png"))
    }
    func entitlement(accessToken: String) async throws -> Entitlement { .init(state: .granted) }
    func usage(accessToken: String) async throws -> UsageProjection { .init(fractionUsed: 1.4, resetsAt: nil, includedAllowance: true, available: true) }
    func calls() -> Int { exchangeCalls }
    func setDelay(_ value: Duration) { exchangeDelay = value }
    func setProfileDelay(_ value: Duration) { profileDelay = value }
    func omitRotatedRefreshToken() { refreshedRefreshToken = "" }
}
private actor ProgressStore: OnboardingStore {
    var data: Data?
    var saveFails = false
    func load() async throws -> Data? { data }
    func save(_ data: Data) async throws { if saveFails { throw TestError.failed }; self.data = data }
    func failSaves() { saveFails = true }
}
private actor FeedbackStub: FeedbackTransport {
    var status = 204; var calls = 0; var delay: Duration = .zero
    func send(_ submission: FeedbackSubmission) async throws -> FeedbackHTTPResponse { calls += 1; try await Task.sleep(for: delay); return .init(statusCode: status) }
    func configure(status: Int, delay: Duration = .zero) { self.status = status; self.delay = delay }
    func count() -> Int { calls }
}
private final class AccountURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw TestError.failed }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func requestBodyString(_ request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}

final class AccountTests: XCTestCase, @unchecked Sendable {
    private func controller(provider: Provider = Provider(), secrets: MemorySecrets = MemorySecrets(), now: @escaping @Sendable () -> Date = Date.init) -> AccountController {
        AccountController(provider: provider, secrets: secrets, authorizationEndpoint: URL(string: "https://identity.example.test/oauth/authorize")!, clientID: "desktop-client", callbackURL: URL(string: "filicon://oauth/callback")!, now: now)
    }

    private func httpProvider(maximumBytes: Int = 1_048_576) throws -> (HTTPSAccountProvider, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let base = URL(string: "https://accounts.example.test")!
        let providerConfiguration = try HTTPSAccountProviderConfiguration(
            clientID: "desktop", redirectURI: URL(string: "filicon://oauth/callback")!,
            tokenEndpoint: base.appendingPathComponent("token"), profileEndpoint: base.appendingPathComponent("profile"),
            entitlementEndpoint: base.appendingPathComponent("entitlement"), usageEndpoint: base.appendingPathComponent("usage"),
            maximumResponseByteCount: maximumBytes
        )
        return (HTTPSAccountProvider(configuration: providerConfiguration, session: session), session)
    }

    func testPKCEAndExactSingleUseCallback() async throws {
        let provider = Provider(), account = controller(provider: provider)
        let request = try await account.beginSignIn()
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertNotNil(components.queryItems?.first(where: { $0.name == "code_challenge" })?.value)
        let callback = URL(string: "filicon://oauth/callback?code=abc&state=\(request.state)")!
        guard case .signedIn(let session) = try await account.handleCallback(callback) else { return XCTFail() }
        XCTAssertEqual(session.profile.displayName, "Ada Lovelace")
        do { _ = try await account.handleCallback(callback); XCTFail("callback must be single-use") } catch { XCTAssertEqual(error as? AuthenticationError, .callbackAlreadyUsed) }
        let callCount = await provider.calls(); XCTAssertEqual(callCount, 1)
    }

    func testCallbackRejectsWrongPathAndStateAndExpiry() async throws {
        let account = controller()
        let request = try await account.beginSignIn()
        do { _ = try await account.handleCallback(URL(string: "filicon://oauth/other?code=x&state=\(request.state)")!); XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .invalidCallback) }
        do { _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=wrong")!); XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .stateMismatch) }
        _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=\(request.state)")!)
        let fixed = Date(timeIntervalSince1970: 100), clock = SequenceClock([fixed, fixed.addingTimeInterval(20)]), expired = controller(now: clock.now)
        let r = try await expired.beginSignIn(validFor: 10)
        do { _ = try await expired.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=\(r.state)")!); XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .stateExpired) }
    }

    func testGenerationFencePreventsLateLoginAfterLogout() async throws {
        let provider = Provider(); await provider.setDelay(.milliseconds(50)); let account = controller(provider: provider)
        let request = try await account.beginSignIn()
        let callback = URL(string: "filicon://oauth/callback?code=late&state=\(request.state)")!
        let task = Task { try await account.handleCallback(callback) }
        try await Task.sleep(for: .milliseconds(10)); _ = await account.logout()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .superseded) }
        let finalState = await account.state; XCTAssertEqual(finalState, .loggedOut(retainedButRevoked: false))
    }

    func testLogoutDeletionFailureRetainsButRevokes() async throws {
        let secrets = MemorySecrets(), account = controller(secrets: secrets)
        let r = try await account.beginSignIn(); _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=\(r.state)")!)
        await secrets.failDeletion()
        let logoutState = await account.logout(); XCTAssertEqual(logoutState, .loggedOut(retainedButRevoked: true))
        let retained = await secrets.contains(AccountController.tokenKey); XCTAssertTrue(retained)
        do { _ = try await account.accessProjection(); XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .notSignedIn) }
        let afterRestart = await controller(secrets: secrets).restore()
        XCTAssertEqual(afterRestart, .loggedOut(retainedButRevoked: true))
    }

    func testLogoutDuringSecretWriteCannotResurrectCredentials() async throws {
        let secrets = MemorySecrets(); await secrets.delayWrites(.milliseconds(50)); let account = controller(secrets: secrets)
        let r = try await account.beginSignIn(), callback = URL(string: "filicon://oauth/callback?code=x&state=\(r.state)")!
        let login = Task { try await account.handleCallback(callback) }
        try await Task.sleep(for: .milliseconds(10)); let logout = Task { await account.logout() }
        do { _ = try await login.value; XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .superseded) }
        let logoutState = await logout.value; XCTAssertEqual(logoutState, .loggedOut(retainedButRevoked: false))
        let retained = await secrets.contains(AccountController.tokenKey); XCTAssertFalse(retained)
    }

    func testProfileBoundsAndUsageClamp() async throws {
        let p = try AccountProfile(id: "x", displayName: String(repeating: "n", count: 121), avatarURL: URL(string: "file:///tmp/a"))
        XCTAssertNil(p.displayName); XCTAssertNil(p.avatarURL)
        XCTAssertThrowsError(try AvatarImage(data: Data(repeating: 0, count: AvatarImage.maximumByteCount + 1), mediaType: "image/png"))
        XCTAssertThrowsError(try AvatarImage(data: Data([1]), mediaType: "text/html"))
        let account = controller(); let r = try await account.beginSignIn(); _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=\(r.state)")!)
        let (_, usage) = try await account.accessProjection(); XCTAssertEqual(usage.fractionUsed, 1)
    }

    func testAuthorizedBearerTokenIsAvailableOnlyForCurrentSignedInState() async throws {
        let account = controller()
        do { _ = try await account.bearerTokenForAuthorizedRequest(); XCTFail() }
        catch { XCTAssertEqual(error as? AuthenticationError, .notSignedIn) }

        let request = try await account.beginSignIn()
        _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=feedback&state=\(request.state)")!)
        let bearer = try await account.bearerTokenForAuthorizedRequest()
        XCTAssertEqual(bearer, "access-feedback")

        _ = await account.logout()
        do { _ = try await account.bearerTokenForAuthorizedRequest(); XCTFail() }
        catch { XCTAssertEqual(error as? AuthenticationError, .notSignedIn) }
    }

    func testDuplicateCallbackParametersAreRejectedWithoutConsumingPendingLogin() async throws {
        let provider = Provider(), account = controller(provider: provider)
        let request = try await account.beginSignIn()
        let duplicate = URL(string: "filicon://oauth/callback?code=x&state=\(request.state)&state=\(request.state)")!
        do { _ = try await account.handleCallback(duplicate); XCTFail() } catch { XCTAssertEqual(error as? AuthenticationError, .stateMismatch) }
        _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=\(request.state)")!)
        let calls = await provider.calls()
        XCTAssertEqual(calls, 1)
    }

    func testRefreshCanPreserveUnrotatedRefreshToken() async throws {
        let provider = Provider(), secrets = MemorySecrets(), account = controller(provider: provider, secrets: secrets)
        let request = try await account.beginSignIn()
        _ = try await account.handleCallback(URL(string: "filicon://oauth/callback?code=x&state=\(request.state)")!)
        await provider.omitRotatedRefreshToken()
        guard case .signedIn = try await account.refresh() else { return XCTFail() }
        guard case .signedIn = await controller(provider: provider, secrets: secrets).restore() else { return XCTFail() }
    }

    func testBackwardAccountAndConnectionDecode() throws {
        let state = try JSONDecoder().decode(AccountState.self, from: Data(#"{"kind":"future-value"}"#.utf8))
        XCTAssertEqual(state, .loggedOut(retainedButRevoked: false))
        let old = try JSONDecoder().decode(ConnectionSnapshot.self, from: Data(#"{"connected":true}"#.utf8))
        XCTAssertEqual(old.phase, .connected)
        let legacy = try JSONDecoder().decode(AccountState.self, from: Data(#"{"kind":"logging-in"}"#.utf8)); XCTAssertEqual(legacy, .signingIn)
        let onboarding = try JSONDecoder().decode(OnboardingProgress.self, from: Data(#"{"seen":true}"#.utf8)); XCTAssertEqual(onboarding.current, .handOff)
        let profileJSON = try JSONSerialization.data(withJSONObject: ["id": "x", "displayName": String(repeating: "x", count: 121), "avatarURL": "file:///tmp/a"])
        let bounded = try JSONDecoder().decode(AccountProfile.self, from: profileJSON)
        XCTAssertNil(bounded.displayName); XCTAssertNil(bounded.avatarURL)
    }

    func testOnboardingDurabilityReadinessAndSuggestions() async throws {
        let store = ProgressStore(), first = OnboardingController(store: store)
        _ = try await first.advance(to: .jobs); _ = try await first.selectSuggestions(["a", "a", " b "])
        let restored = try await OnboardingController(store: store).restore()
        XCTAssertTrue(restored.completed.contains(.meet)); XCTAssertEqual(restored.selectedSuggestionIDs, ["a", "b"])
        XCTAssertEqual(OnboardingReadiness(accountSignedIn: true, serviceReachable: true, resourceCount: 1).state, .ready)
        let catalog = [OnboardingSuggestion(id: "generic", title: "G", priority: 1), OnboardingSuggestion(id: "git", title: "Git", requiredCapability: "git", priority: 5)]
        XCTAssertEqual(selectOnboardingSuggestions(catalog, capabilities: ["git"]).map(\.id), ["git", "generic"])

        let failingStore = ProgressStore(), transactional = OnboardingController(store: failingStore)
        await failingStore.failSaves()
        do { _ = try await transactional.advance(to: .jobs); XCTFail() } catch { }
        let progress = await transactional.progress
        XCTAssertEqual(progress.current, .landing)
    }

    func testFeedbackValidationIdempotencyHTTPAndDeadline() async throws {
        XCTAssertThrowsError(try FeedbackSubmission(message: "   "))
        let transport = FeedbackStub(), client = FeedbackClient(transport: transport), id = UUID()
        let payload = try FeedbackSubmission(message: " hello ", submissionID: id, conversationID: " c1 ")
        try await client.submit(payload); try await client.submit(payload); let count = await transport.count(); XCTAssertEqual(count, 1)
        await transport.configure(status: 429)
        do { try await client.submit(try .init(message: "again")); XCTFail() } catch { XCTAssertEqual(error as? FeedbackError, .rateLimited) }
        await transport.configure(status: 204, delay: .milliseconds(100))
        do { try await client.submit(try .init(message: "slow"), deadline: .milliseconds(5)); XCTFail() } catch { XCTAssertEqual(error as? FeedbackError, .deadlineExceeded) }
    }

    func testConnectionStateMachineDistinguishesReconnect() {
        var machine = ConnectionStateMachine(); XCTAssertEqual(machine.send(.show).phase, .loading)
        XCTAssertEqual(machine.send(.failed).phase, .unreachable); XCTAssertEqual(machine.send(.retryStarted).phase, .loading)
        _ = machine.send(.succeeded); XCTAssertEqual(machine.send(.failed).phase, .reconnecting)
        XCTAssertEqual(machine.send(.retryStarted).phase, .reconnecting); XCTAssertTrue(machine.snapshot.isRetrying)
    }

    func testHTTPSProviderUsesFormPKCEBearerAndBoundedJSON() async throws {
        let (provider, session) = try httpProvider()
        defer { session.invalidateAndCancel() }
        AccountURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "token":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = requestBodyString(request)
                let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?\(body)")?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
                XCTAssertEqual(fields["code_verifier"], String(repeating: "v", count: 43))
                XCTAssertEqual(fields["redirect_uri"], "filicon://oauth/callback")
                return (200, Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8))
            case "profile":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
                return (200, Data(#"{"id":"u1","email":"u@example.test","display_name":"User"}"#.utf8))
            default: return (404, Data())
            }
        }
        let tokens = try await provider.exchange(code: "code", redirectURI: URL(string: "filicon://oauth/callback")!, verifier: String(repeating: "v", count: 43))
        XCTAssertEqual(tokens.accessToken, "access")
        let profile = try await provider.profile(accessToken: tokens.accessToken)
        XCTAssertEqual(profile.displayName, "User")
        do {
            _ = try await provider.exchange(code: "code", redirectURI: URL(string: "other://oauth/callback")!, verifier: String(repeating: "v", count: 43))
            XCTFail()
        } catch { XCTAssertEqual(error as? AccountProviderError, .authorizationRejected) }

        let (bounded, boundedSession) = try httpProvider(maximumBytes: 8)
        defer { boundedSession.invalidateAndCancel() }
        do {
            _ = try await bounded.exchange(code: "code", redirectURI: URL(string: "filicon://oauth/callback")!, verifier: String(repeating: "v", count: 43))
            XCTFail()
        } catch { XCTAssertEqual(error as? HTTPSAccountProviderError, .responseTooLarge) }
    }

    func testHTTPSFeedbackAndAtomicPrivateOnboardingStore() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        AccountURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer feedback-token")
            return (202, Data(#"{"accepted":true}"#.utf8))
        }
        let transport = try HTTPSFeedbackTransport(endpoint: URL(string: "https://feedback.example.test/v1/feedback")!, session: session, bearerToken: { "feedback-token" })
        let response = try await transport.send(try .init(message: "hello"))
        XCTAssertEqual(response.statusCode, 202)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("onboarding.json")
        let store = FileOnboardingStore(fileURL: url)
        let data = Data(#"{"current":"landing"}"#.utf8)
        try await store.save(data)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, data)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }
}
