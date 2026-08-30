import Darwin
import Foundation
import Testing
import FiliconAppServices

private enum InjectedQuotaCrash: Error { case crash }

@Suite("App-wide storage quota")
struct StorageQuotaTests {
    @Test func enforcesEightMiBRecordAndTwoHundredFiftySixMiBTotalDefaults() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger(rootURL: root)
        let tooLarge = StorageQuotaRecord(scope: "messages", key: "large", byteCount: 8 * 1_024 * 1_024 + 1, generation: 1)
        await #expect(throws: StorageQuotaError.recordTooLarge(limit: 8 * 1_024 * 1_024, requested: tooLarge.byteCount)) {
            _ = try await ledger.reserve(tooLarge)
        }
        let exact = StorageQuotaRecord(scope: "messages", key: "exact", byteCount: 8 * 1_024 * 1_024, generation: 1)
        _ = try await ledger.reserve(exact)
        for index in 0..<31 {
            _ = try await ledger.reserve(.init(scope: "messages", key: "fill-\(index)", byteCount: 8 * 1_024 * 1_024, generation: 1))
        }
        await #expect(throws: StorageQuotaError.totalExceeded(limit: 256 * 1_024 * 1_024, projected: 264 * 1_024 * 1_024)) {
            _ = try await ledger.reserve(.init(scope: "messages", key: "over-total", byteCount: 8 * 1_024 * 1_024, generation: 1))
        }
    }

    @Test func casContentIsChargedOnceAcrossLogicalRecords() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 8, totalBytes: 8))
        let first = try await ledger.reserve(.init(scope: "attachments", key: "one", byteCount: 6, contentID: "sha256:same", generation: 1))
        _ = try await ledger.commit(first.id)
        let second = try await ledger.reserve(.init(scope: "attachments", key: "two", byteCount: 6, contentID: "sha256:same", generation: 1))
        _ = try await ledger.commit(second.id)
        let usage = await ledger.usage()
        #expect(usage.committedBytes == 6)
        #expect(usage.recordCount == 2)
        await #expect(throws: StorageQuotaError.contentSizeConflict("sha256:same")) {
            _ = try await ledger.reserve(.init(scope: "attachments", key: "three", byteCount: 7, contentID: "sha256:same", generation: 1))
        }
    }

    @Test func reservationsPreventConcurrentOvercommitAndReleaseCapacity() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 1, totalBytes: 5))
        let accepted = await withTaskGroup(of: StorageQuotaReservation?.self, returning: [StorageQuotaReservation].self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await ledger.reserve(.init(scope: "records", key: "\(index)", byteCount: 1, generation: 1))
                }
            }
            var result: [StorageQuotaReservation] = []
            for await reservation in group { if let reservation { result.append(reservation) } }
            return result
        }
        #expect(accepted.count == 5)
        let usage = await ledger.usage()
        #expect(usage.projectedBytes == 5)
        await #expect(throws: StorageQuotaError.self) {
            _ = try await ledger.reserve(.init(scope: "records", key: "overflow", byteCount: 1, generation: 1))
        }
        try await ledger.release(accepted[0].id)
        _ = try await ledger.reserve(.init(scope: "records", key: "replacement", byteCount: 1, generation: 1))
    }

    @Test func commitIsReplayableAfterCrashAndLedgerGenerationPersists() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_000)
        let normal = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 20), clock: { now })
        let token = UUID()
        let record = StorageQuotaRecord(scope: "messages", key: "one", byteCount: 7, generation: 1)
        _ = try await normal.reserve(record, token: token)
        let crashing = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 20), clock: { now }, faultInjector: {
            if $0 == .afterCommitPersist { throw InjectedQuotaCrash.crash }
        })
        await #expect(throws: InjectedQuotaCrash.self) { _ = try await crashing.commit(token) }

        let reopened = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 20), clock: { now })
        #expect(try await reopened.commit(token) == record)
        #expect(await reopened.usage().ledgerGeneration >= 2)
    }

    @Test func preRenameCrashLeavesNoPhantomReservationAndTempIsReconciled() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID()
        let crashing = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10), faultInjector: {
            if $0 == .afterTemporaryWriteBeforeRename { throw InjectedQuotaCrash.crash }
        })
        await #expect(throws: InjectedQuotaCrash.self) {
            _ = try await crashing.reserve(.init(scope: "x", key: "y", byteCount: 5, generation: 1), token: token)
        }
        let reopened = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10))
        #expect(await reopened.usage().reservationCount == 0)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!entries.contains(where: { $0.hasPrefix(".storage-quota-") }))
    }

    @Test func persistedReservationAndReleaseReplayAcrossInjectedCrashes() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID()
        let record = StorageQuotaRecord(scope: "cache", key: "item", byteCount: 5, generation: 1)
        let reserveCrash = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10), faultInjector: {
            if $0 == .afterReservationPersist { throw InjectedQuotaCrash.crash }
        })
        await #expect(throws: InjectedQuotaCrash.self) { _ = try await reserveCrash.reserve(record, token: token) }
        let reopened = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10))
        #expect(try await reopened.reserve(record, token: token).id == token)

        let releaseCrash = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10), faultInjector: {
            if $0 == .afterReleasePersist { throw InjectedQuotaCrash.crash }
        })
        await #expect(throws: InjectedQuotaCrash.self) { try await releaseCrash.release(token) }
        let afterRelease = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10))
        #expect(await afterRelease.usage().reservationCount == 0)
    }

    @Test func generationRejectsStaleWritersAndTokenPayloadChanges() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 20))
        let first = try await ledger.reserve(.init(scope: "settings", key: "main", byteCount: 2, generation: 2))
        _ = try await ledger.commit(first.id)
        await #expect(throws: StorageQuotaError.staleGeneration(current: 2, proposed: 2)) {
            _ = try await ledger.reserve(.init(scope: "settings", key: "main", byteCount: 3, generation: 2))
        }
        let token = UUID()
        _ = try await ledger.reserve(.init(scope: "settings", key: "other", byteCount: 1, generation: 1), token: token)
        await #expect(throws: StorageQuotaError.reservationConflict) {
            _ = try await ledger.reserve(.init(scope: "settings", key: "changed", byteCount: 1, generation: 1), token: token)
        }
    }

    @Test func reconcileUsesAuthoritativeRecordsAndExpiresReservations() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 2_000)
        let ledger = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 20, reservationLifetime: 5), clock: { start })
        let pending = try await ledger.reserve(.init(scope: "orphan", key: "pending", byteCount: 4, generation: 1))
        let later = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 20, reservationLifetime: 5), clock: { start.addingTimeInterval(6) })
        await #expect(throws: StorageQuotaError.expiredReservation(pending.id)) { _ = try await later.commit(pending.id) }
        let authoritative = StorageQuotaRecord(scope: "actual", key: "row", byteCount: 6, contentID: "same", generation: 4)
        let usage = try await ledger.reconcile(authoritativeRecords: [authoritative], now: start.addingTimeInterval(6))
        #expect(usage.committedBytes == 6)
        #expect(usage.reservationCount == 0)
        #expect(await ledger.record(scope: "orphan", key: "pending") == nil)
        #expect(await ledger.record(scope: "actual", key: "row") == authoritative)
    }

    @Test func quotaDirectoryAndLedgerArePrivateAndSymlinkRootIsRejected() async throws {
        let sandbox = try makeSandbox(); defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appending(path: "quota")
        let ledger = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10))
        let reservation = try await ledger.reserve(.init(scope: "a", key: "b", byteCount: 1, generation: 1))
        _ = try await ledger.commit(reservation.id)
        #expect(mode(root) == 0o700)
        #expect(mode(root.appending(path: "storage-quota-v1.json")) == 0o600)

        let link = sandbox.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: StorageQuotaError.unsafeRoot) { _ = try StorageQuotaLedger(rootURL: link) }
    }

    @Test func emptyCASIdentityCannotCollapseUnrelatedRecords() async throws {
        let root = try makeSandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger(rootURL: root, configuration: .init(perRecordBytes: 10, totalBytes: 10))
        await #expect(throws: StorageQuotaError.invalidRecord) {
            _ = try await ledger.reserve(.init(scope: "a", key: "b", byteCount: 1, contentID: "", generation: 1))
        }
    }

    private func makeSandbox() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func mode(_ url: URL) -> mode_t {
        var info = stat(); guard lstat(url.path, &info) == 0 else { return 0 }; return info.st_mode & 0o777
    }
}
