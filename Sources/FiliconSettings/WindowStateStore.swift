import Foundation

public struct WindowBounds: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    fileprivate var isValid: Bool {
        width > 0 && height > 0
    }
}

public struct WindowState: Codable, Equatable, Sendable {
    public var version: Int
    public var normalBounds: WindowBounds
    public var isMaximized: Bool

    public init(version: Int = 1, normalBounds: WindowBounds, isMaximized: Bool) {
        self.version = version
        self.normalBounds = normalBounds
        self.isMaximized = isMaximized
    }
}

public struct WindowSnapshot: Equatable, Sendable {
    public var currentBounds: WindowBounds
    public var normalBounds: WindowBounds
    public var isMaximized: Bool
    public var isFullScreen: Bool

    public init(currentBounds: WindowBounds, normalBounds: WindowBounds, isMaximized: Bool, isFullScreen: Bool) {
        self.currentBounds = currentBounds
        self.normalBounds = normalBounds
        self.isMaximized = isMaximized
        self.isFullScreen = isFullScreen
    }
}

public struct WindowPlacement: Equatable, Sendable {
    public var bounds: WindowBounds
    public var shouldMaximize: Bool
    public var usedPersistedBounds: Bool

    public init(bounds: WindowBounds, shouldMaximize: Bool, usedPersistedBounds: Bool) {
        self.bounds = bounds
        self.shouldMaximize = shouldMaximize
        self.usedPersistedBounds = usedPersistedBounds
    }
}

public enum WindowGeometry {
    public static let minimumWidth = 512
    public static let minimumHeight = 520
    public static let fallbackWidth = 1040
    public static let fallbackHeight = 760
    public static let minimumVisibleWidth = 100
    public static let minimumVisibleHeight = 40

    public static func resolve(state: WindowState?, workAreas: [WindowBounds]) -> WindowPlacement {
        let usable = workAreas.filter {
            $0.isValid && $0.width >= minimumWidth && $0.height >= minimumHeight
        }
        guard let state, state.version == 1, state.normalBounds.isValid else {
            return fallback(in: usable.first)
        }
        guard !usable.isEmpty else {
            return WindowPlacement(
                bounds: WindowBounds(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight),
                shouldMaximize: state.isMaximized,
                usedPersistedBounds: false
            )
        }
        let ranked = usable.map { area in (area, overlap(state.normalBounds, area)) }
            .sorted { lhs, rhs in lhs.1.area > rhs.1.area }
        let best = ranked[0]
        let remainedVisible = best.1.width >= minimumVisibleWidth && best.1.height >= minimumVisibleHeight
        let target = remainedVisible ? best.0 : usable[0]
        return WindowPlacement(
            bounds: clamp(state.normalBounds, to: target),
            shouldMaximize: state.isMaximized,
            usedPersistedBounds: remainedVisible
        )
    }

    private static func fallback(in area: WindowBounds?) -> WindowPlacement {
        guard let area else {
            return WindowPlacement(
                bounds: WindowBounds(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight),
                shouldMaximize: false,
                usedPersistedBounds: false
            )
        }
        let width = min(max(minimumWidth, fallbackWidth), area.width)
        let height = min(max(minimumHeight, fallbackHeight), area.height)
        return WindowPlacement(
            bounds: WindowBounds(
                x: area.x + max(0, (area.width - width) / 2),
                y: area.y + max(0, (area.height - height) / 2),
                width: width,
                height: height
            ),
            shouldMaximize: false,
            usedPersistedBounds: false
        )
    }

    private static func clamp(_ bounds: WindowBounds, to area: WindowBounds) -> WindowBounds {
        let width = min(max(bounds.width, minimumWidth), area.width)
        let height = min(max(bounds.height, minimumHeight), area.height)
        let x = min(max(bounds.x, area.x), area.x + area.width - width)
        let y = min(max(bounds.y, area.y), area.y + area.height - height)
        return WindowBounds(x: x, y: y, width: width, height: height)
    }

    private static func overlap(_ lhs: WindowBounds, _ rhs: WindowBounds) -> (width: Int, height: Int, area: Int) {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        return (width, height, width * height)
    }
}

public actor WindowStateStore {
    public typealias ScreenGeometryProvider = @Sendable () -> [WindowBounds]
    public typealias Clock = @Sendable () -> Date

    public let fileURL: URL
    private let fileManager: FileManager
    private let clock: Clock
    private let screenGeometry: ScreenGeometryProvider
    private var lastNormalBounds: WindowBounds?

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        clock: @escaping Clock = Date.init,
        screenGeometry: @escaping ScreenGeometryProvider
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.clock = clock
        self.screenGeometry = screenGeometry
    }

    public func load() -> WindowState? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let state = try JSONDecoder().decode(WindowState.self, from: Data(contentsOf: fileURL))
            guard state.version == 1, state.normalBounds.isValid else { throw WindowStateError.invalidState }
            lastNormalBounds = state.normalBounds
            return state
        } catch {
            quarantineMalformedFile()
            return nil
        }
    }

    public func launchPlacement() -> WindowPlacement {
        WindowGeometry.resolve(state: load(), workAreas: screenGeometry())
    }

    /// Records normal/maximized state. Full-screen transitions deliberately do not mutate persisted state.
    public func record(_ snapshot: WindowSnapshot) throws {
        guard !snapshot.isFullScreen else { return }
        let normal: WindowBounds
        if snapshot.isMaximized {
            normal = lastNormalBounds ?? snapshot.normalBounds
        } else {
            normal = snapshot.currentBounds
            lastNormalBounds = normal
        }
        guard normal.isValid else { throw WindowStateError.invalidState }
        try persist(WindowState(normalBounds: normal, isMaximized: snapshot.isMaximized))
    }

    private func persist(_ state: WindowState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettySorted.encode(state)
        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func quarantineMalformedFile() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let timestamp = Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down))
        var destination = fileURL.appendingPathExtension("corrupt-\(timestamp)")
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: fileURL.appendingPathExtension("corrupt-\(timestamp)").path + "-\(suffix)")
            suffix += 1
        }
        try? fileManager.moveItem(at: fileURL, to: destination)
    }
}

public enum WindowStateError: Error, Equatable {
    case invalidState
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
