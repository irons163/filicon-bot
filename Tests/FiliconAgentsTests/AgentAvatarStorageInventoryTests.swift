import CustomDump
import Darwin
import FiliconAgents
import Foundation
import Testing

@Suite("Physical avatar storage accounting")
struct AgentAvatarStorageInventoryTests {
    @Test func includesOrphansTemporaryFilesAndCorruptBytesWithoutDeleting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "avatar-inventory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAvatarStore(rootURL: root)
        expectNoDifference(try store.storageInventory(), [])
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root.appending(path: "ab"), withIntermediateDirectories: true)
        let files = ["ab/orphan.png": Data(repeating: 1, count: 31),
                     "ab/.unfinished.tmp": Data(repeating: 2, count: 7), "corrupt": Data("broken".utf8)]
        for (name, data) in files { try data.write(to: root.appending(path: name)) }
        let entries = try store.storageInventory()
        expectNoDifference(entries.map(\.relativePath), files.keys.sorted())
        expectNoDifference(entries.map(\.byteCount), [7, 31, 6])
        for (name, data) in files { expectNoDifference(try Data(contentsOf: root.appending(path: name)), data) }
        expectNoDifference(try AgentAvatarStore(rootURL: root).storageInventory(), entries)
    }

    @Test(arguments: ["root-link", "file-link", "directory-link", "fifo", "deep-directory"])
    func rejectsUnsafeInventoryRatherThanCountingItAsZero(mode: String) throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: "avatar-inventory-unsafe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appending(path: "cas"), outside = sandbox.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        if mode == "root-link" {
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            switch mode {
            case "file-link":
                let file = outside.appending(path: "secret")
                try Data("private".utf8).write(to: file)
                try FileManager.default.createSymbolicLink(at: root.appending(path: "blob"), withDestinationURL: file)
            case "directory-link":
                try FileManager.default.createSymbolicLink(at: root.appending(path: "ab"), withDestinationURL: outside)
            case "fifo":
                #expect(mkfifo(root.appending(path: "pipe").path, 0o600) == 0)
            default:
                try FileManager.default.createDirectory(at: root.appending(path: "ab/deeper"), withIntermediateDirectories: true)
            }
        }
        #expect(throws: AgentAvatarStoreError.unsafePath) { try AgentAvatarStore(rootURL: root).storageInventory() }
    }
}
