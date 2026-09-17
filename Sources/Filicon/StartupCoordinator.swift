import AppKit
import Darwin
import FiliconAppServices
import Foundation

struct AppStartupContext: Sendable {
    let root: URL
    let settlement: StartupDataRootSettlement
    let warning: String?

    static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> AppStartupContext {
        let canonical = homeDirectory.appending(path: "Library/Application Support/Filicon", directoryHint: .isDirectory)
        var warning: String?
        if let raw = environment["FILICON_DATA_ROOT"], !raw.isEmpty {
            do {
                let root = try validatedOverride(raw)
                return .init(root: root, settlement: .init(route: .unchanged, reason: .dataRootOverride, root: root), warning: nil)
            } catch {
                warning = "FILICON_DATA_ROOT was ignored because it is not a safe absolute directory: \(String(error.localizedDescription.prefix(500)))"
            }
        }
        // Packaged, swift run, and Xcode launches share the same data root.
        // Never discover or migrate another application's private directory.
        let settlement = try StartupDataRootSettler.prepareCanonicalRoot(canonical)
        return .init(root: canonical, settlement: settlement, warning: warning)
    }

    static func isolated(root: URL, reason: StartupDataRootReason = .lab) throws -> AppStartupContext {
        let value = try validatedExplicitRoot(root)
        return .init(root: value, settlement: .init(route: .unchanged, reason: reason, root: value), warning: nil)
    }

    private static func validatedOverride(_ raw: String) throws -> URL {
        guard !raw.contains("\0"), !raw.contains("\n"), !raw.contains("\r"), !raw.contains("://") else { throw StartupContextError.unsafeOverride }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        guard raw.hasPrefix("/"), url.path == raw || url.path + "/" == raw else { throw StartupContextError.unsafeOverride }
        return try validatedExplicitRoot(url)
    }

    private static func validatedExplicitRoot(_ raw: URL) throws -> URL {
        guard raw.isFileURL, raw.path.hasPrefix("/"), raw.pathComponents.contains("..") == false else { throw StartupContextError.unsafeOverride }
        let root = raw.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            current.append(path: component)
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw StartupContextError.unsafeOverride }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }
}

enum StartupContextError: LocalizedError {
    case unsafeOverride
    var errorDescription: String? { "The override must be an absolute, non-symlink local directory without traversal components." }
}

enum WorkspaceRootConnectionPhase: String, Sendable { case loading, connected, reconnecting, unreachable }

struct WorkspaceRootConnection: Equatable, Sendable {
    var phase: WorkspaceRootConnectionPhase = .loading
    var failureCount = 0
    var message: String?
}

struct WorkspaceRootTicket: Equatable, Sendable {
    let rootGeneration: UInt64
    let accountGeneration: UInt64
}

/// Single-flight, generation-fenced retry state used by AppModel. A request
/// arriving while disconnected is retained exactly once for the next success.
@MainActor
final class WorkspaceRootResilience {
    private(set) var connection = WorkspaceRootConnection()
    private(set) var generation: UInt64 = 1
    private(set) var accountGeneration: UInt64 = 1
    private(set) var hasQueuedReload = false
    private var retryTask: Task<Void, Never>?

    func begin(accountGeneration: UInt64? = nil) -> WorkspaceRootTicket {
        if let accountGeneration, accountGeneration != self.accountGeneration {
            self.accountGeneration = accountGeneration
            invalidate()
        }
        connection.phase = connection.phase == .connected ? .reconnecting : .loading
        return .init(rootGeneration: generation, accountGeneration: self.accountGeneration)
    }

    func fail(_ error: Error, ticket: WorkspaceRootTicket) {
        guard accepts(ticket) else { return }
        connection.failureCount += 1
        connection.phase = connection.phase == .reconnecting ? .reconnecting : .unreachable
        connection.message = String(error.localizedDescription.prefix(1_000))
    }

    func succeed(ticket: WorkspaceRootTicket) -> Bool {
        guard accepts(ticket) else { return false }
        connection = .init(phase: .connected)
        let queued = hasQueuedReload
        hasQueuedReload = false
        return queued
    }

    func invalidate() { generation &+= 1; retryTask?.cancel(); retryTask = nil }
    func updateAccountGeneration(_ value: UInt64) {
        guard value != accountGeneration else { return }
        accountGeneration = value
        invalidate()
    }
    func queueReload() { hasQueuedReload = true }

    func retry(_ operation: @escaping @MainActor @Sendable (WorkspaceRootTicket) async -> Void) {
        guard retryTask == nil else { return }
        let ticket = begin()
        retryTask = Task { [weak self] in
            await operation(ticket)
            self?.retryTask = nil
        }
    }

    private func accepts(_ ticket: WorkspaceRootTicket) -> Bool {
        ticket.rootGeneration == generation && ticket.accountGeneration == accountGeneration
    }
}

actor AppQuotaWriter {
    private let ledger: StorageQuotaLedger
    private var generations: [String: UInt64] = [:]

    init(ledger: StorageQuotaLedger) { self.ledger = ledger }

    func reconcile(_ records: [StorageQuotaRecord]) async throws -> StorageQuotaUsage {
        for record in records { generations[record.scope + "\u{1f}" + record.key] = record.generation }
        return try await ledger.reconcile(authoritativeRecords: records)
    }

    func perform<T: Sendable>(scope: String, key: String, data: Data, operation: @Sendable () async throws -> T) async throws -> T {
        let identity = scope + "\u{1f}" + key
        let current: UInt64
        if let known = generations[identity] { current = known }
        else { current = await ledger.record(scope: scope, key: key)?.generation ?? 0 }
        let generation = current + 1
        let reservation = try await ledger.reserve(.init(scope: scope, key: key, byteCount: Int64(data.count), generation: generation))
        do {
            let value = try await operation()
            _ = try await ledger.commit(reservation.id)
            generations[identity] = generation
            return value
        } catch {
            try? await ledger.release(reservation.id)
            throw error
        }
    }
}
