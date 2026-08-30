import Darwin
import Foundation

public struct StorageQuotaRecord: Codable, Hashable, Sendable {
    public let scope: String
    public let key: String
    public let byteCount: Int64
    /// Equal content ids are charged once (for example a SHA-256 CAS id).
    public let contentID: String?
    public let generation: UInt64

    public init(scope: String, key: String, byteCount: Int64, contentID: String? = nil, generation: UInt64) {
        self.scope = scope; self.key = key; self.byteCount = byteCount
        self.contentID = contentID; self.generation = generation
    }

    fileprivate var recordID: String { "\(scope)\u{1f}\(key)" }
    fileprivate var chargeID: String { contentID.map { "cas:\($0)" } ?? "record:\(recordID)" }
}

public struct StorageQuotaReservation: Codable, Equatable, Sendable {
    public let id: UUID
    public let record: StorageQuotaRecord
    public let createdAt: Date
    public let expiresAt: Date
}

public struct StorageQuotaUsage: Codable, Equatable, Sendable {
    public let committedBytes: Int64
    public let projectedBytes: Int64
    public let recordCount: Int
    public let reservationCount: Int
    public let ledgerGeneration: UInt64
}

public enum StorageQuotaError: Error, Equatable, Sendable {
    case invalidRecord
    case recordTooLarge(limit: Int64, requested: Int64)
    case totalExceeded(limit: Int64, projected: Int64)
    case staleGeneration(current: UInt64, proposed: UInt64)
    case contentSizeConflict(String)
    case reservationConflict
    case missingReservation(UUID)
    case expiredReservation(UUID)
    case corruptLedger
    case unsafeRoot
}

public enum StorageQuotaFaultPoint: String, Sendable {
    case afterTemporaryWriteBeforeRename
    case afterReservationPersist
    case afterCommitPersist
    case afterReleasePersist
    case afterReconcilePersist
}

public struct StorageQuotaConfiguration: Sendable {
    public var perRecordBytes: Int64
    public var totalBytes: Int64
    public var reservationLifetime: TimeInterval

    public init(perRecordBytes: Int64 = 8 * 1_024 * 1_024, totalBytes: Int64 = 256 * 1_024 * 1_024, reservationLifetime: TimeInterval = 15 * 60) {
        self.perRecordBytes = perRecordBytes
        self.totalBytes = totalBytes
        self.reservationLifetime = max(0, reservationLifetime)
    }
}

/// Durable app-wide quota authority. Reservations are persisted before bytes
/// are written; commits are token-idempotent and generation-checked.
public actor StorageQuotaLedger {
    public typealias Clock = @Sendable () -> Date
    public typealias FaultInjector = @Sendable (StorageQuotaFaultPoint) throws -> Void

    private struct Completed: Codable, Sendable {
        let record: StorageQuotaRecord
        let completedAt: Date
    }
    private struct State: Codable, Sendable {
        var version = 1
        var ledgerGeneration: UInt64 = 0
        var records: [String: StorageQuotaRecord] = [:]
        var reservations: [UUID: StorageQuotaReservation] = [:]
        var completed: [UUID: Completed] = [:]
    }

    private let rootURL: URL
    private let ledgerURL: URL
    private let configuration: StorageQuotaConfiguration
    private let clock: Clock
    private let injectFault: FaultInjector
    private var state: State

    public init(
        rootURL: URL,
        configuration: StorageQuotaConfiguration = .init(),
        clock: @escaping Clock = Date.init,
        faultInjector: @escaping FaultInjector = { _ in }
    ) throws {
        guard configuration.perRecordBytes >= 0, configuration.totalBytes >= 0,
              configuration.reservationLifetime.isFinite else { throw StorageQuotaError.invalidRecord }
        self.rootURL = rootURL
        ledgerURL = rootURL.appending(path: "storage-quota-v1.json")
        self.configuration = configuration
        self.clock = clock
        self.injectFault = faultInjector
        let loaded = try Self.load(rootURL: rootURL, ledgerURL: ledgerURL)
        guard loaded.records.allSatisfy({ $0.key == $0.value.recordID && Self.isValid($0.value, configuration: configuration) }),
              loaded.reservations.allSatisfy({ $0.key == $0.value.id && Self.isValid($0.value.record, configuration: configuration) }),
              loaded.completed.allSatisfy({ Self.isValid($0.value.record, configuration: configuration) }) else {
            throw StorageQuotaError.corruptLedger
        }
        let reservationRecordIDs = loaded.reservations.values.map(\.record.recordID)
        guard Set(reservationRecordIDs).count == reservationRecordIDs.count else { throw StorageQuotaError.corruptLedger }
        var projected = loaded.records
        for reservation in loaded.reservations.values {
            guard reservation.record.generation > (loaded.records[reservation.record.recordID]?.generation ?? 0) else {
                throw StorageQuotaError.corruptLedger
            }
            projected[reservation.record.recordID] = reservation.record
        }
        guard Self.hasConsistentContentSizes(Array(projected.values)) else { throw StorageQuotaError.corruptLedger }
        guard Self.chargedBytes(Array(projected.values)) <= configuration.totalBytes else { throw StorageQuotaError.corruptLedger }
        state = loaded
    }

    /// AppModel integration point after startup data-root settlement.
    public static func live(
        dataRoot: URL,
        configuration: StorageQuotaConfiguration = .init(),
        clock: @escaping Clock = Date.init,
        faultInjector: @escaping FaultInjector = { _ in }
    ) throws -> StorageQuotaLedger {
        try .init(rootURL: dataRoot.appending(path: "quota", directoryHint: .isDirectory), configuration: configuration, clock: clock, faultInjector: faultInjector)
    }

    public func reserve(_ record: StorageQuotaRecord, token: UUID = UUID()) throws -> StorageQuotaReservation {
        try validate(record)
        if let existing = state.reservations[token] {
            guard existing.record == record else { throw StorageQuotaError.reservationConflict }
            return existing
        }
        if let completed = state.completed[token] {
            guard completed.record == record else { throw StorageQuotaError.reservationConflict }
            return .init(id: token, record: record, createdAt: completed.completedAt, expiresAt: completed.completedAt)
        }
        if state.reservations.values.contains(where: { $0.record.recordID == record.recordID }) {
            throw StorageQuotaError.reservationConflict
        }
        if let contentID = record.contentID,
           (Array(state.records.values) + state.reservations.values.map(\.record)).contains(where: { $0.contentID == contentID && $0.byteCount != record.byteCount }) {
            throw StorageQuotaError.contentSizeConflict(contentID)
        }
        let current = state.records[record.recordID]?.generation ?? 0
        guard record.generation > current else { throw StorageQuotaError.staleGeneration(current: current, proposed: record.generation) }
        let projected = projectedBytes(adding: record)
        guard projected <= configuration.totalBytes else { throw StorageQuotaError.totalExceeded(limit: configuration.totalBytes, projected: projected) }
        let now = clock()
        let reservation = StorageQuotaReservation(id: token, record: record, createdAt: now, expiresAt: now.addingTimeInterval(configuration.reservationLifetime))
        state.reservations[token] = reservation
        try persist()
        try injectFault(.afterReservationPersist)
        return reservation
    }

    @discardableResult
    public func commit(_ reservationID: UUID) throws -> StorageQuotaRecord {
        if let completed = state.completed[reservationID] { return completed.record }
        guard let reservation = state.reservations[reservationID] else { throw StorageQuotaError.missingReservation(reservationID) }
        guard reservation.expiresAt > clock() else { throw StorageQuotaError.expiredReservation(reservationID) }
        let current = state.records[reservation.record.recordID]?.generation ?? 0
        guard reservation.record.generation > current else {
            throw StorageQuotaError.staleGeneration(current: current, proposed: reservation.record.generation)
        }
        state.records[reservation.record.recordID] = reservation.record
        state.reservations.removeValue(forKey: reservationID)
        state.completed[reservationID] = .init(record: reservation.record, completedAt: clock())
        trimCompleted()
        try persist()
        try injectFault(.afterCommitPersist)
        return reservation.record
    }

    public func release(_ reservationID: UUID) throws {
        guard state.reservations.removeValue(forKey: reservationID) != nil else { return }
        try persist()
        try injectFault(.afterReleasePersist)
    }

    /// Removes a committed logical record. CAS bytes remain charged while any
    /// other logical record references the same content id.
    public func remove(scope: String, key: String, expectedGeneration: UInt64? = nil) throws {
        let id = "\(scope)\u{1f}\(key)"
        guard let current = state.records[id] else { return }
        if let expectedGeneration, current.generation != expectedGeneration {
            throw StorageQuotaError.staleGeneration(current: current.generation, proposed: expectedGeneration)
        }
        state.records.removeValue(forKey: id)
        try persist()
    }

    public func usage() -> StorageQuotaUsage {
        .init(
            committedBytes: Self.chargedBytes(Array(state.records.values)),
            projectedBytes: projectedBytes(adding: nil),
            recordCount: state.records.count,
            reservationCount: state.reservations.count,
            ledgerGeneration: state.ledgerGeneration
        )
    }

    public func record(scope: String, key: String) -> StorageQuotaRecord? { state.records["\(scope)\u{1f}\(key)"] }

    /// Replays startup against an authoritative scan of actual stores and
    /// expires abandoned reservations. Passing nil preserves committed rows.
    @discardableResult
    public func reconcile(authoritativeRecords: [StorageQuotaRecord]? = nil, now: Date? = nil) throws -> StorageQuotaUsage {
        let instant = now ?? clock()
        var reconciledRecords = state.records
        if let authoritativeRecords {
            var replacement: [String: StorageQuotaRecord] = [:]
            for record in authoritativeRecords {
                try validate(record)
                if let prior = replacement[record.recordID] {
                    if prior.generation == record.generation, prior != record { throw StorageQuotaError.corruptLedger }
                    if prior.generation > record.generation { continue }
                }
                replacement[record.recordID] = record
            }
            guard Self.chargedBytes(Array(replacement.values)) <= configuration.totalBytes else {
                throw StorageQuotaError.totalExceeded(limit: configuration.totalBytes, projected: Self.chargedBytes(Array(replacement.values)))
            }
            guard Self.hasConsistentContentSizes(Array(replacement.values)) else { throw StorageQuotaError.corruptLedger }
            reconciledRecords = replacement
        }
        let reconciledReservations = state.reservations.filter { _, reservation in
            reservation.expiresAt > instant && reservation.record.generation > (reconciledRecords[reservation.record.recordID]?.generation ?? 0)
        }
        var projectedRecords = reconciledRecords
        for reservation in reconciledReservations.values { projectedRecords[reservation.record.recordID] = reservation.record }
        let projected = Self.chargedBytes(Array(projectedRecords.values))
        guard projected <= configuration.totalBytes else {
            throw StorageQuotaError.totalExceeded(limit: configuration.totalBytes, projected: projected)
        }
        state.records = reconciledRecords
        state.reservations = reconciledReservations
        trimCompleted()
        try persist()
        try injectFault(.afterReconcilePersist)
        return usage()
    }

    private func validate(_ record: StorageQuotaRecord) throws {
        guard Self.isValid(record, configuration: configuration) else {
            if record.byteCount > configuration.perRecordBytes {
                throw StorageQuotaError.recordTooLarge(limit: configuration.perRecordBytes, requested: record.byteCount)
            }
            throw StorageQuotaError.invalidRecord
        }
        guard record.byteCount <= configuration.perRecordBytes else {
            throw StorageQuotaError.recordTooLarge(limit: configuration.perRecordBytes, requested: record.byteCount)
        }
    }

    private static func isValid(_ record: StorageQuotaRecord, configuration: StorageQuotaConfiguration) -> Bool {
        !record.scope.isEmpty && !record.key.isEmpty && record.scope.utf8.count <= 128 && record.key.utf8.count <= 512
            && !record.scope.contains("\u{1f}") && !record.key.contains("\u{1f}") && record.generation > 0 && record.byteCount >= 0
            && record.byteCount <= configuration.perRecordBytes && (record.contentID?.utf8.count ?? 0) <= 512
            && (record.contentID == nil || record.contentID?.isEmpty == false)
    }

    private func projectedBytes(adding record: StorageQuotaRecord?) -> Int64 {
        var records = state.records
        if let record { records[record.recordID] = record }
        var all = Array(records.values)
        for reservation in state.reservations.values where reservation.record.recordID != record?.recordID {
            all.append(reservation.record)
        }
        return Self.chargedBytes(all)
    }

    private static func chargedBytes(_ records: [StorageQuotaRecord]) -> Int64 {
        var charges: [String: Int64] = [:]
        for record in records { charges[record.chargeID] = max(charges[record.chargeID] ?? 0, record.byteCount) }
        var result: Int64 = 0
        for value in charges.values {
            let (sum, overflow) = result.addingReportingOverflow(value)
            if overflow { return .max }
            result = sum
        }
        return result
    }

    private static func hasConsistentContentSizes(_ records: [StorageQuotaRecord]) -> Bool {
        var sizes: [String: Int64] = [:]
        for record in records {
            guard let contentID = record.contentID else { continue }
            if let size = sizes[contentID], size != record.byteCount { return false }
            sizes[contentID] = record.byteCount
        }
        return true
    }

    private func trimCompleted() {
        guard state.completed.count > 1_024 else { return }
        let remove = state.completed.sorted {
            $0.value.completedAt == $1.value.completedAt
                ? $0.key.uuidString < $1.key.uuidString
                : $0.value.completedAt < $1.value.completedAt
        }.prefix(state.completed.count - 1_024)
        for item in remove { state.completed.removeValue(forKey: item.key) }
    }

    private func persist() throws {
        guard state.ledgerGeneration < .max else { throw StorageQuotaError.corruptLedger }
        state.ledgerGeneration += 1
        let data = try JSONEncoder.stable.encode(state)
        try Self.ensureSafeRoot(rootURL)
        let temporary = rootURL.appending(path: ".storage-quota-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StorageQuotaError.corruptLedger
        }
        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw StorageQuotaError.corruptLedger }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, chmod(temporary.path, 0o600) == 0 else { throw StorageQuotaError.corruptLedger }
        try injectFault(.afterTemporaryWriteBeforeRename)
        guard Darwin.rename(temporary.path, ledgerURL.path) == 0 else { throw StorageQuotaError.corruptLedger }
        let directoryDescriptor = open(rootURL.path, O_RDONLY)
        if directoryDescriptor >= 0 { _ = fsync(directoryDescriptor); close(directoryDescriptor) }
    }

    private static func load(rootURL: URL, ledgerURL: URL) throws -> State {
        try ensureSafeRoot(rootURL)
        for entry in (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix(".storage-quota-") && entry.pathExtension == "tmp" {
            try? FileManager.default.removeItem(at: entry)
        }
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return State() }
        var info = stat()
        guard lstat(ledgerURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw StorageQuotaError.corruptLedger }
        guard chmod(ledgerURL.path, 0o600) == 0 else { throw StorageQuotaError.corruptLedger }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: ledgerURL), var loaded = try? decoder.decode(State.self, from: data), loaded.version == 1 else {
            throw StorageQuotaError.corruptLedger
        }
        loaded.completed = loaded.completed.filter { !$0.value.record.recordID.isEmpty }
        return loaded
    }

    private static func ensureSafeRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw StorageQuotaError.unsafeRoot }
        guard chmod(root.path, 0o700) == 0 else { throw StorageQuotaError.unsafeRoot }
    }
}

private extension JSONEncoder {
    static var stable: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
