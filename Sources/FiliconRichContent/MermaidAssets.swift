import CryptoKit
import Foundation

/// A clean public distribution, not recovered opaque app bytes. Loading this
/// value grants no navigation, file, network, script-message or tool capability.
public struct OfflineMermaidResources: Sendable {
    public let script: String
    public static let engineVersion = "11.16.0"
    public static let verified: Self? = load()

    private static func load() -> Self? {
        load(searchRoots: [Bundle.main.resourceURL, Bundle(for: MermaidBundleFinder.self).resourceURL,
                           Bundle.main.bundleURL].compactMap { $0 })
    }

    static func load(searchRoots: [URL]) -> Self? {
        for candidate in searchRoots {
            let url = candidate.appendingPathComponent("Filicon_FiliconRichContent.bundle")
            if isSymbolicLink(url) { return nil }
            guard let bundle = Bundle(url: url) else { continue }
            guard let root = bundle.url(forResource: "Mermaid", withExtension: nil) else { return nil }
            return load(root: root)
        }
        return nil
    }

    static func load(root: URL) -> Self? {
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink == false }) == true,
              let manifest = regularData(at: root.appendingPathComponent("manifest.json"), within: root, maximum: 262_144),
              digest(manifest) == "9a4d4a9751de0820b953ef699dcf0382c80612ce5c7c6146fea65761749c462b",
              let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["package"] as? String == "mermaid", object["version"] as? String == engineVersion,
              let components = object["components"] as? [[String: Any]], components.count == 72,
              let files = object["files"] as? [String: [String: Any]], files.count == 74,
              files["LICENSE"] != nil, files["mermaid.min.js"] != nil else { return nil }
        var script: String?, total = 0
        for (path, metadata) in files {
            guard safePath(path), let count = metadata["bytes"] as? Int, count > 0, count <= 4_194_304,
                  total + count <= 8_388_608,
                  let bytes = regularData(at: root.appendingPathComponent(path), within: root, maximum: count),
                  bytes.count == count, digest(bytes) == metadata["sha256"] as? String else { return nil }
            total += count
            if path == "mermaid.min.js" { script = String(data: bytes, encoding: .utf8) }
        }
        guard let script, !script.isEmpty else { return nil }
        return .init(script: script)
    }

    private static func safePath(_ path: String) -> Bool {
        if path == "LICENSE" || path == "mermaid.min.js" { return true }
        return !path.contains("..") && path.range(of: #"^notices/[a-z0-9+_.-]+/(licen[sc]e|copying|notice)(\.(txt|md|markdown|rst))?$"#,
                                                 options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func regularData(at url: URL, within root: URL, maximum: Int) -> Data? {
        var cursor = url
        while cursor != root {
            guard !isSymbolicLink(cursor), cursor.pathComponents.count > root.pathComponents.count else { return nil }
            cursor.deleteLastPathComponent()
        }
        guard !isSymbolicLink(root), let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize, size <= maximum,
              let bytes = try? Data(contentsOf: url), bytes.count <= maximum else { return nil }
        return bytes
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

private final class MermaidBundleFinder {}
