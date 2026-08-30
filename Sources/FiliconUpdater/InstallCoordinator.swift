import Darwin
import Foundation
import Security

public struct PreparedUpdateInstall: Codable, Equatable, Sendable {
    public var preparedApplication: URL
    public var targetApplication: URL
    public var expectedBundleIdentifier: String
    public var expectedVersion: String
    public var expectedBuild: Int
    public var sourceProcessIdentifier: Int32
    public var relaunchAfterInstall: Bool

    public init(
        preparedApplication: URL,
        targetApplication: URL,
        expectedBundleIdentifier: String,
        expectedVersion: String,
        expectedBuild: Int,
        sourceProcessIdentifier: Int32,
        relaunchAfterInstall: Bool = true
    ) throws {
        guard preparedApplication.isFileURL,
              targetApplication.isFileURL,
              preparedApplication.pathExtension == "app",
              targetApplication.pathExtension == "app",
              !expectedBundleIdentifier.isEmpty,
              !expectedVersion.isEmpty,
              expectedBuild > 0,
              sourceProcessIdentifier >= 0 else {
            throw UpdateError.invalidArtifactName
        }
        self.preparedApplication = preparedApplication.standardizedFileURL
        self.targetApplication = targetApplication.standardizedFileURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedVersion = expectedVersion
        self.expectedBuild = expectedBuild
        self.sourceProcessIdentifier = sourceProcessIdentifier
        self.relaunchAfterInstall = relaunchAfterInstall
    }
}

public enum ApplicationBundleVerifier {
    public static func verify(
        _ application: URL,
        bundleIdentifier: String,
        version: String? = nil,
        build: Int? = nil
    ) throws {
        guard application.isFileURL,
              application.pathExtension == "app",
              let bundle = Bundle(url: application),
              bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.invalidApplicationBundle("bundle identifier mismatch")
        }
        if let version,
           bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String != version {
            throw UpdateError.invalidApplicationBundle("version mismatch")
        }
        if let build {
            let raw = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            guard raw.flatMap(Int.init) == build else {
                throw UpdateError.invalidApplicationBundle("build mismatch")
            }
        }
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(application as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw UpdateError.codeSignatureInvalid(createStatus)
        }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else { throw UpdateError.codeSignatureInvalid(status) }
    }
}

public actor UpdateInstallCoordinator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func prepare(
        staged: StagedUpdate,
        stagingDirectory: URL,
        targetApplication: URL,
        expectedBundleIdentifier: String,
        sourceProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> PreparedUpdateInstall {
        let root = stagingDirectory.standardizedFileURL
        let artifact = root.appending(path: staged.artifactPath).standardizedFileURL
        guard artifact.path.hasPrefix(root.path + "/"), fileManager.fileExists(atPath: artifact.path) else {
            throw UpdateError.invalidArtifactName
        }
        let preparationRoot = root.appending(path: ".prepared-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: preparationRoot, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: preparationRoot) } }

        let extracted: URL
        switch staged.release.artifact.format {
        case .appZip:
            try run("/usr/bin/ditto", ["-x", "-k", artifact.path, preparationRoot.path])
            extracted = try uniqueApplication(in: preparationRoot)
        case .dmg:
            extracted = try extractDMG(artifact, into: preparationRoot)
        }
        try ApplicationBundleVerifier.verify(
            extracted,
            bundleIdentifier: expectedBundleIdentifier,
            version: staged.release.version,
            build: staged.release.build
        )
        let plan = try PreparedUpdateInstall(
            preparedApplication: extracted,
            targetApplication: targetApplication,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedVersion: staged.release.version,
            expectedBuild: staged.release.build,
            sourceProcessIdentifier: sourceProcessIdentifier
        )
        let planURL = preparationRoot.appending(path: "install-plan.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: planURL, options: .atomic)
        committed = true
        return plan
    }

    public func launchHelper(for plan: PreparedUpdateInstall, helperURL: URL) throws {
        guard helperURL.isFileURL, fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw UpdateError.helperUnavailable
        }
        let planURL = plan.preparedApplication.deletingLastPathComponent().appending(path: "install-plan.json")
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [planURL.path]
        try process.run()
    }

    private func extractDMG(_ artifact: URL, into destination: URL) throws -> URL {
        let output = try runCapturing("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-readonly", artifact.path])
        guard let plist = try PropertyListSerialization.propertyList(from: output, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.extractionFailed("disk image did not provide a mount point")
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPath]) }
        let mountedApp = try uniqueApplication(in: URL(fileURLWithPath: mountPath, isDirectory: true))
        let copied = destination.appending(path: mountedApp.lastPathComponent, directoryHint: .isDirectory)
        try fileManager.copyItem(at: mountedApp, to: copied)
        return copied
    }

    private func uniqueApplication(in root: URL) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw UpdateError.extractionFailed("cannot enumerate extracted artifact") }
        var applications: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "app" {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw UpdateError.invalidApplicationBundle("application is not a regular directory")
            }
            applications.append(url)
            enumerator.skipDescendants()
        }
        guard applications.count == 1 else {
            throw UpdateError.extractionFailed("expected exactly one application bundle")
        }
        return applications[0]
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        try runCapturing(executable, arguments)
    }

    private func runCapturing(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.prefix(1_000), as: UTF8.self)
            throw UpdateError.extractionFailed(message)
        }
        return data
    }
}

public enum PreparedUpdateApplier {
    public typealias Verifier = @Sendable (URL, String, String?, Int?) throws -> Void

    public static func apply(
        _ plan: PreparedUpdateInstall,
        fileManager: FileManager = .default,
        verifier: Verifier = ApplicationBundleVerifier.verify
    ) throws {
        try validatePlanPaths(plan)
        waitForProcessExit(plan.sourceProcessIdentifier)
        try verifier(plan.preparedApplication, plan.expectedBundleIdentifier, plan.expectedVersion, plan.expectedBuild)

        let parent = plan.targetApplication.deletingLastPathComponent().standardizedFileURL
        let backup = parent.appending(path: ".\(plan.targetApplication.lastPathComponent).backup-\(UUID().uuidString)")
        var movedOld = false
        do {
            if fileManager.fileExists(atPath: plan.targetApplication.path) {
                try verifier(plan.targetApplication, plan.expectedBundleIdentifier, nil, nil)
                try fileManager.moveItem(at: plan.targetApplication, to: backup)
                movedOld = true
            }
            try fileManager.moveItem(at: plan.preparedApplication, to: plan.targetApplication)
            try verifier(plan.targetApplication, plan.expectedBundleIdentifier, plan.expectedVersion, plan.expectedBuild)
            if movedOld { try fileManager.removeItem(at: backup) }
        } catch {
            if fileManager.fileExists(atPath: plan.targetApplication.path) {
                try? fileManager.removeItem(at: plan.targetApplication)
            }
            if movedOld { try? fileManager.moveItem(at: backup, to: plan.targetApplication) }
            throw UpdateError.installFailed(error.localizedDescription)
        }
        if plan.relaunchAfterInstall {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [plan.targetApplication.path]
            try process.run()
        }
    }

    private static func validatePlanPaths(_ plan: PreparedUpdateInstall) throws {
        let prepared = plan.preparedApplication.standardizedFileURL
        let target = plan.targetApplication.standardizedFileURL
        guard prepared.isFileURL, target.isFileURL,
              prepared.pathExtension == "app", target.pathExtension == "app",
              prepared.path != target.path,
              target.deletingLastPathComponent().path != "/" else {
            throw UpdateError.invalidArtifactName
        }
    }

    private static func waitForProcessExit(_ identifier: Int32) {
        guard identifier > 1 else { return }
        let deadline = Date().addingTimeInterval(120)
        while kill(identifier, 0) == 0, Date() < deadline { usleep(200_000) }
    }
}
