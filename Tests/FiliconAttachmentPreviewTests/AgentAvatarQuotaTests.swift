import AppKit
import CustomDump
import FiliconAgents
import FiliconAppServices
import Foundation
import Testing
@testable import Filicon

@Suite("Image avatar physical quota", .serialized)
@MainActor
struct AgentAvatarQuotaTests {
    private func image(_ store: AgentAvatarStore) throws -> PreparedAgentAvatar {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)
        return try store.prepareImage(data: svg)
    }

    @Test(arguments: ["save", "profile-failure", "closed", "stale", "account", "archived"])
    func hostCommitChargesBlobBeforeProfileAndPreservesOrphans(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avatar-quota-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let owner = try #require(await model.createAgent(name: "Owner", summary: "", instructions: "PRIVATE",
            providerID: "fixture", modelID: "test"))
        let scope = UUID()
        model.runningGroups.insert(scope)
        let store = AgentAvatarStore(rootURL: root.appending(path: "agent-avatars"))
        let prepared = try image(store)
        let lifetime = AgentAvatarChangeLifetime()
        let change = AgentAvatarChange(operation: .set, agentID: owner.id,
            previousAvatar: mode == "stale" ? .pet(.dewey) : owner.avatar, image: prepared)
        if mode == "closed" { lifetime.close() }
        if mode == "archived" { await model.archiveAgent(id: owner.id) }
        if mode == "profile-failure" {
            let state = root.appending(path: "agents.json")
            try FileManager.default.removeItem(at: state)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        }
        if mode == "save" {
            let saved = try await model.commitAgentAvatarChange(change, lifetime: lifetime, originID: scope, generation: 1)
            expectNoDifference(saved.avatar, prepared.avatar)
            expectNoDifference(saved.instructions, "PRIVATE")
            let repeated = AgentAvatarChange(operation: .set, agentID: owner.id, previousAvatar: saved.avatar, image: prepared)
            _ = try await model.commitAgentAvatarChange(repeated, lifetime: .init(), originID: scope, generation: 1)
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await model.commitAgentAvatarChange(change, lifetime: lifetime, originID: scope, generation: mode == "account" ? 99 : 1)
            }
            expectNoDifference(lifetime.committedProfile(for: change), nil)
        }
        let inventory = try store.storageInventory()
        let ledger = try StorageQuotaLedger.live(dataRoot: root)
        let record = await ledger.record(scope: "avatar-blob", key: prepared.avatar.imageRelativePath!)
        if mode == "save" || mode == "profile-failure" {
            expectNoDifference(inventory.count, 1)
            expectNoDifference(record?.byteCount, Int64(prepared.pngData.count))
            expectNoDifference(store.imageData(for: prepared.avatar), prepared.pngData)
        } else {
            expectNoDifference(inventory, [])
            expectNoDifference(record, nil)
        }
        let usage = await ledger.usage()
        expectNoDifference(usage.reservationCount, 0)
    }

    @Test(arguments: ["save", "full", "corrupt", "cancel", "invalid"])
    func manualImportReservesBeforeInstalling(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avatar-manual-quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "selected.svg")
        let bytes = Data((mode == "invalid" ? "not an image" : "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>").utf8)
        try bytes.write(to: source)
        if mode == "full" {
            let ledger = try StorageQuotaLedger.live(dataRoot: root)
            _ = try await ledger.reconcile(authoritativeRecords: (0..<32).map {
                StorageQuotaRecord(scope: "fixture", key: "\($0)", byteCount: 8 * 1_024 * 1_024, generation: 1)
            })
        }
        if mode == "corrupt" {
            let quota = root.appending(path: "quota")
            try FileManager.default.createDirectory(at: quota, withIntermediateDirectories: true)
            try Data("invalid ledger".utf8).write(to: quota.appending(path: "storage-quota-v1.json"))
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let work = Task { await model.importAgentAvatar(from: source, crop: .init(), shape: .hexagon) }
        if mode == "cancel" { work.cancel() }
        let avatar = await work.value
        let store = AgentAvatarStore(rootURL: root.appending(path: "agent-avatars"))
        if mode == "save" {
            let saved = try #require(avatar)
            expectNoDifference(saved.shape, .hexagon)
            let again = await model.importAgentAvatar(from: source, crop: .init(), shape: .hexagon)
            expectNoDifference(again, saved)
            expectNoDifference(try store.storageInventory().count, 1)
            let data = try #require(store.imageData(for: saved))
            let ledger = try StorageQuotaLedger.live(dataRoot: root)
            let record = await ledger.record(scope: "avatar-blob", key: saved.imageRelativePath!)
            expectNoDifference(record?.byteCount, Int64(data.count))
            let usage = await ledger.usage()
            expectNoDifference(usage.reservationCount, 0)
        } else {
            expectNoDifference(avatar, nil)
            expectNoDifference(try store.storageInventory(), [])
        }
        expectNoDifference(try Data(contentsOf: source), bytes)
        #expect(model.agents.isEmpty)
    }

    @Test func quotaDenialDoesNotInstallBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avatar-quota-denial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAvatarStore(rootURL: root.appending(path: "cas"))
        let prepared = try image(store)
        let ledger = try StorageQuotaLedger(rootURL: root.appending(path: "quota"),
            configuration: .init(perRecordBytes: 1_024 * 1_024, totalBytes: Int64(prepared.pngData.count - 1)))
        let writer = AppQuotaWriter(ledger: ledger)
        await #expect(throws: StorageQuotaError.self) {
            _ = try await writer.perform(scope: "avatar-blob", key: prepared.avatar.imageRelativePath!, data: prepared.pngData) {
                try store.install(prepared)
            }
        }
        expectNoDifference(try store.storageInventory(), [])
        let usage = await ledger.usage()
        expectNoDifference(usage.reservationCount, 0)
    }

    @Test func reconciliationKeepsOrphanChargeAndDoesNotReplaceLedgerOnUnsafeScan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avatar-quota-reconcile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAvatarStore(rootURL: root.appending(path: "agent-avatars"))
        let prepared = try image(store)
        _ = try store.install(prepared)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reconcileQuota()
        let key = prepared.avatar.imageRelativePath!
        let first = try StorageQuotaLedger.live(dataRoot: root)
        let firstRecord = await first.record(scope: "avatar-blob", key: key)
        expectNoDifference(firstRecord?.byteCount, Int64(prepared.pngData.count))
        try FileManager.default.createSymbolicLink(at: store.rootURL.appending(path: "unsafe"), withDestinationURL: root)
        await model.reconcileQuota()
        #expect(model.errorMessage != nil)
        let reopened = try StorageQuotaLedger.live(dataRoot: root)
        let reopenedRecord = await reopened.record(scope: "avatar-blob", key: key)
        expectNoDifference(reopenedRecord?.byteCount, Int64(prepared.pngData.count))
    }

    @Test func unavailableQuotaAuthorityCannotInstallImage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avatar-quota-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let quota = root.appending(path: "quota")
        try FileManager.default.createDirectory(at: quota, withIntermediateDirectories: true)
        try Data("invalid ledger".utf8).write(to: quota.appending(path: "storage-quota-v1.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let owner = try #require(await model.createAgent(name: "Owner", summary: "", instructions: "",
            providerID: "fixture", modelID: "test"))
        let scope = UUID()
        model.runningGroups.insert(scope)
        let store = AgentAvatarStore(rootURL: root.appending(path: "agent-avatars"))
        let change = AgentAvatarChange(operation: .set, agentID: owner.id, previousAvatar: owner.avatar, image: try image(store))
        await #expect(throws: StorageQuotaError.corruptLedger) {
            _ = try await model.commitAgentAvatarChange(change, lifetime: .init(), originID: scope, generation: 1)
        }
        expectNoDifference(try store.storageInventory(), [])
    }
}
