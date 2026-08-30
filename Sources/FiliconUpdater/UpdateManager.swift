import Foundation

public struct UpdateConfiguration: Codable, Equatable, Sendable {
    public var channel: UpdateChannel
    public var feedURL: URL
    public var automaticallyChecks: Bool
    public var automaticallyDownloads: Bool
    public var requiresSignature: Bool
    public var trustedEd25519PublicKey: Data?

    public init(
        channel: UpdateChannel = .stable,
        feedURL: URL,
        automaticallyChecks: Bool = true,
        automaticallyDownloads: Bool = false,
        requiresSignature: Bool = true,
        trustedEd25519PublicKey: Data? = nil
    ) throws {
        guard feedURL.scheme?.lowercased() == "https", feedURL.host != nil else {
            throw UpdateError.insecureURL
        }
        if requiresSignature, trustedEd25519PublicKey == nil {
            throw UpdateError.invalidPublicKey
        }
        self.channel = channel
        self.feedURL = feedURL
        self.automaticallyChecks = automaticallyChecks
        self.automaticallyDownloads = automaticallyDownloads
        self.requiresSignature = requiresSignature
        self.trustedEd25519PublicKey = trustedEd25519PublicKey
    }

    public var signaturePolicy: SignaturePolicy {
        guard let key = trustedEd25519PublicKey else { return .disabled }
        return requiresSignature ? .required(publicKey: key) : .ifPresent(publicKey: key)
    }
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(UpdateRelease)
    case downloading(UpdateRelease)
    case staged(StagedUpdate, directory: URL)
    case installing(StagedUpdate)
    case failed(String)
}

public protocol UpdateSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousUpdateSleeper: UpdateSleeping {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

public actor UpdateManager {
    public typealias StateObserver = @Sendable (UpdateState) async -> Void

    private let service: UpdateService
    private let stagingRoot: URL
    private let schedule: UpdateCheckSchedule
    private let sleeper: any UpdateSleeping
    private let randomUnit: @Sendable () -> Double
    private var state: UpdateState = .idle
    private var periodicTask: Task<Void, Never>?

    public init(
        service: UpdateService = UpdateService(),
        stagingRoot: URL,
        schedule: UpdateCheckSchedule = UpdateCheckSchedule(),
        sleeper: any UpdateSleeping = ContinuousUpdateSleeper(),
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.service = service
        self.stagingRoot = stagingRoot
        self.schedule = schedule
        self.sleeper = sleeper
        self.randomUnit = randomUnit
    }

    deinit { periodicTask?.cancel() }

    public func snapshot() -> UpdateState { state }

    @discardableResult
    public func check(
        configuration: UpdateConfiguration,
        installed: InstalledVersion,
        systemVersion: String,
        now: Date = Date(),
        observer: StateObserver? = nil
    ) async -> UpdateState {
        await transition(.checking, observer: observer)
        do {
            let feed = try await service.fetchFeed(from: configuration.feedURL, channel: configuration.channel)
            guard let release = try UpdateSelector.newestUpdate(
                in: feed,
                channel: configuration.channel,
                installed: installed,
                systemVersion: systemVersion
            ) else {
                await transition(.upToDate(checkedAt: now), observer: observer)
                return state
            }
            await transition(.available(release), observer: observer)
            if configuration.automaticallyDownloads {
                return await stage(release, configuration: configuration, observer: observer)
            }
        } catch {
            await transition(.failed(Self.sanitized(error)), observer: observer)
        }
        return state
    }

    @discardableResult
    public func stage(
        _ release: UpdateRelease,
        configuration: UpdateConfiguration,
        observer: StateObserver? = nil
    ) async -> UpdateState {
        await transition(.downloading(release), observer: observer)
        do {
            let staged = try await service.downloadAndStage(
                release,
                in: stagingRoot,
                signaturePolicy: configuration.signaturePolicy
            )
            let directory = stagingRoot.appending(path: "\(release.version)-\(release.build)", directoryHint: .isDirectory)
            await transition(.staged(staged, directory: directory), observer: observer)
        } catch {
            await transition(.failed(Self.sanitized(error)), observer: observer)
        }
        return state
    }

    public func startPeriodicChecks(
        configuration: UpdateConfiguration,
        installed: InstalledVersion,
        systemVersion: String,
        observer: StateObserver? = nil,
        afterCheck: (@Sendable () async -> Void)? = nil
    ) {
        periodicTask?.cancel()
        guard configuration.automaticallyChecks else { return }
        periodicTask = Task { [weak self, schedule, sleeper, randomUnit] in
            do { try await sleeper.sleep(for: schedule.initialDelay) }
            catch { return }
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.check(
                    configuration: configuration,
                    installed: installed,
                    systemVersion: systemVersion,
                    observer: observer
                )
                await afterCheck?()
                do { try await sleeper.sleep(for: schedule.nextPeriodicDelay(randomUnit: randomUnit())) }
                catch { return }
            }
        }
    }

    public func stopPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    private func transition(_ next: UpdateState, observer: StateObserver?) async {
        state = next
        await observer?(next)
    }

    private static func sanitized(_ error: Error) -> String {
        String(error.localizedDescription.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined().prefix(1_000))
    }
}
