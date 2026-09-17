import Darwin
import Foundation

struct SpreadsheetPreview: Equatable, Sendable {
    struct Sheet: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let rows: [[String]]
    }

    let sheets: [Sheet]
    let isTruncated: Bool
}

enum SpreadsheetPreviewError: LocalizedError, Equatable {
    case unsupportedEncoding
    case delimitedTooLarge
    case archiveToolUnavailable
    case archiveTooLarge
    case archiveExpansionLimit
    case archiveEntryLimit
    case unsafeArchiveEntry(String)
    case malformedWorkbook
    case rowLimit
    case columnLimit
    case textLimit
    case processFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: l10n("The table is not valid UTF-8.")
        case .delimitedTooLarge: l10n("The CSV/TSV file exceeds the 8 MB preview limit.")
        case .archiveToolUnavailable: l10n("The system ZIP reader is unavailable; use Quick Look instead.")
        case .archiveTooLarge: l10n("The XLSX archive exceeds the 50 MB preview limit.")
        case .archiveExpansionLimit: l10n("The XLSX archive exceeds safe expansion limits.")
        case .archiveEntryLimit: l10n("The XLSX archive contains too many files.")
        case .unsafeArchiveEntry(let name): l10n("The XLSX archive contains an unsafe entry: \(name)")
        case .malformedWorkbook: l10n("The XLSX workbook could not be parsed safely.")
        case .rowLimit: l10n("The table exceeds the 2,000-row preview limit.")
        case .columnLimit: l10n("The table exceeds the 200-column preview limit.")
        case .textLimit: l10n("The table contains more text than can be previewed safely.")
        case .processFailed: l10n("The system ZIP reader failed.")
        }
    }
}

enum SpreadsheetPreviewLimits {
    static let delimitedBytes = 8 * 1_024 * 1_024
    static let archiveBytes: Int64 = 50 * 1_024 * 1_024
    static let expandedBytes: Int64 = 100 * 1_024 * 1_024
    static let archiveEntries = 5_000
    static let rows = 2_000
    static let columns = 200
    static let cellCharacters = 16_384
    static let totalCharacters = 2_000_000
    static let sheets = 20
    static let sharedStrings = 200_000
    static let relationships = 10_000
    static let expansionRatio: Int64 = 100
    static let xmlBytes = 32 * 1_024 * 1_024
}

struct DelimitedTextPreviewParser {
    func parse(fileURL: URL, delimiter: Character, name: String = "Table") throws -> SpreadsheetPreview {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SpreadsheetPreviewError.unsafeArchiveEntry(fileURL.lastPathComponent)
        }
        guard (values.fileSize ?? 0) <= SpreadsheetPreviewLimits.delimitedBytes else {
            throw SpreadsheetPreviewError.delimitedTooLarge
        }
        return try parse(data: Data(contentsOf: fileURL, options: [.mappedIfSafe]), delimiter: delimiter, name: name)
    }

    func parse(data: Data, delimiter: Character, name: String = "Table") throws -> SpreadsheetPreview {
        guard data.count <= SpreadsheetPreviewLimits.delimitedBytes else { throw SpreadsheetPreviewError.delimitedTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw SpreadsheetPreviewError.unsupportedEncoding }
        guard delimiter == "," || delimiter == "\t" else {
            throw SpreadsheetPreviewError.malformedWorkbook
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var totalCharacters = 0
        var index = text.startIndex

        func validateField(_ value: String) throws {
            guard value.count <= SpreadsheetPreviewLimits.cellCharacters else {
                throw SpreadsheetPreviewError.textLimit
            }
        }

        func appendField() throws {
            try validateField(field)
            totalCharacters += field.count
            guard totalCharacters <= SpreadsheetPreviewLimits.totalCharacters else {
                throw SpreadsheetPreviewError.textLimit
            }
            row.append(field)
            field.removeAll(keepingCapacity: true)
            guard row.count <= SpreadsheetPreviewLimits.columns else {
                throw SpreadsheetPreviewError.columnLimit
            }
        }

        func appendRow() throws {
            try appendField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
            guard rows.count <= SpreadsheetPreviewLimits.rows else {
                throw SpreadsheetPreviewError.rowLimit
            }
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                } else if character == "\r\n" {
                    field.append("\n")
                } else if character == "\r" {
                    // RFC 4180 permits CRLF inside quoted fields. Normalize both
                    // CRLF and legacy bare CR without leaving a stray carriage
                    // return in text copied from the preview.
                    if next < text.endIndex, text[next] == "\n" { index = next }
                    field.append("\n")
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty {
                quoted = true
            } else if character == delimiter {
                try appendField()
            } else if character == "\n" {
                try appendRow()
            } else if character == "\r\n" {
                try appendRow()
            } else if character == "\r" {
                if next < text.endIndex, text[next] == "\n" { index = next }
                try appendRow()
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }

        guard !quoted else { throw SpreadsheetPreviewError.malformedWorkbook }
        if !field.isEmpty || !row.isEmpty { try appendRow() }
        return SpreadsheetPreview(
            sheets: [.init(id: "delimited", name: name, rows: rows)],
            isTruncated: false
        )
    }
}

struct XLSXArchiveEntry: Equatable, Sendable {
    let path: String
    let uncompressedBytes: Int64
    let isDirectory: Bool
}

struct XLSXArchivePolicy {
    func validate(entries: [XLSXArchiveEntry], archiveBytes: Int64) throws {
        guard archiveBytes > 0, archiveBytes <= SpreadsheetPreviewLimits.archiveBytes else {
            throw SpreadsheetPreviewError.archiveTooLarge
        }
        guard entries.count <= SpreadsheetPreviewLimits.archiveEntries else {
            throw SpreadsheetPreviewError.archiveEntryLimit
        }
        var expanded: Int64 = 0
        for entry in entries {
            guard isSafeRelativePath(entry.path) else {
                throw SpreadsheetPreviewError.unsafeArchiveEntry(entry.path)
            }
            let (sum, overflow) = expanded.addingReportingOverflow(entry.uncompressedBytes)
            guard !overflow, entry.uncompressedBytes >= 0 else {
                throw SpreadsheetPreviewError.archiveExpansionLimit
            }
            expanded = sum
        }
        let (ratioLimit, ratioOverflow) = archiveBytes.multipliedReportingOverflow(
            by: SpreadsheetPreviewLimits.expansionRatio
        )
        guard !ratioOverflow,
              expanded <= SpreadsheetPreviewLimits.expandedBytes,
              expanded <= ratioLimit else {
            throw SpreadsheetPreviewError.archiveExpansionLimit
        }
    }

    func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1_024,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let first = parts.first, first.count == 2,
           first.last == ":", first.first?.isASCII == true,
           first.first?.isLetter == true { return false }
        return parts.enumerated().allSatisfy { index, component in
            if component.isEmpty { return index == parts.count - 1 && path.hasSuffix("/") }
            return component != "." && component != ".."
        }
    }
}

/// XLSX parsing is deliberately read-only: formulas, macros, external links,
/// relationships outside the archive, and embedded objects are never loaded.
struct XLSXPreviewParser {
    private let fileManager = FileManager.default
    private let policy = XLSXArchivePolicy()

    func parse(fileURL: URL) throws -> SpreadsheetPreview {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SpreadsheetPreviewError.unsafeArchiveEntry(fileURL.lastPathComponent)
        }
        let archiveBytes = Int64(values.fileSize ?? 0)
        guard archiveBytes <= SpreadsheetPreviewLimits.archiveBytes else {
            throw SpreadsheetPreviewError.archiveTooLarge
        }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/zipinfo"),
              fileManager.isExecutableFile(atPath: "/usr/bin/ditto") else {
            throw SpreadsheetPreviewError.archiveToolUnavailable
        }

        let listing = try ProcessRunner.run(
            executable: "/usr/bin/zipinfo",
            arguments: ["-l", fileURL.path],
            timeout: 10
        )
        let namesOutput = try ProcessRunner.run(
            executable: "/usr/bin/zipinfo",
            arguments: ["-1", fileURL.path],
            timeout: 10
        )
        let names = try parseNames(namesOutput)
        let entries = try parseListing(listing)
        guard entries.map(\.path) == names else {
            // Never let an unknown central-directory mode disappear from the
            // safety preflight while the extractor still sees the entry.
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        try policy.validate(entries: entries, archiveBytes: archiveBytes)

        let root = fileManager.temporaryDirectory
            .appending(path: "FiliconXLSX-\(UUID().uuidString)", directoryHint: .isDirectory)
        let expanded = root.appending(path: "expanded", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: expanded, withIntermediateDirectories: true)
        _ = try ProcessRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", "--noqtn", fileURL.path, expanded.path],
            timeout: 20,
            monitoredDirectory: expanded,
            maxMonitoredBytes: SpreadsheetPreviewLimits.expandedBytes,
            maxMonitoredEntries: SpreadsheetPreviewLimits.archiveEntries
        )
        try validateExpandedTree(expanded)
        return try parseWorkbook(root: expanded)
    }

    private func parseListing(_ output: Data) throws -> [XLSXArchiveEntry] {
        guard let value = String(data: output, encoding: .utf8) else {
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        var entries: [XLSXArchiveEntry] = []
        for line in value.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(maxSplits: 9, whereSeparator: \Character.isWhitespace)
            guard parts.count == 10 else { continue }
            let permissions = parts[0]
            guard let first = permissions.first, first == "-" || first == "d" || first == "l",
                  let size = Int64(parts[3]) else { continue }
            let path = String(parts[9])
            if first == "l" { throw SpreadsheetPreviewError.unsafeArchiveEntry(path) }
            entries.append(.init(path: path, uncompressedBytes: size, isDirectory: first == "d"))
        }
        guard !entries.isEmpty else { throw SpreadsheetPreviewError.malformedWorkbook }
        return entries
    }

    private func parseNames(_ output: Data) throws -> [String] {
        guard let value = String(data: output, encoding: .utf8) else {
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        let names = value.split(whereSeparator: \Character.isNewline).map(String.init)
        guard !names.isEmpty else { throw SpreadsheetPreviewError.malformedWorkbook }
        for name in names where !policy.isSafeRelativePath(name) {
            throw SpreadsheetPreviewError.unsafeArchiveEntry(name)
        }
        return names
    }

    private func validateExpandedTree(_ root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw SpreadsheetPreviewError.malformedWorkbook }
        let prefix = root.standardizedFileURL.path + "/"
        var count = 0
        var bytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= SpreadsheetPreviewLimits.archiveEntries,
                  url.standardizedFileURL.path.hasPrefix(prefix) else {
                throw SpreadsheetPreviewError.archiveEntryLimit
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw SpreadsheetPreviewError.unsafeArchiveEntry(url.lastPathComponent)
            }
            if values.isRegularFile == true {
                let (nextBytes, overflow) = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                guard !overflow, nextBytes <= SpreadsheetPreviewLimits.expandedBytes else {
                    throw SpreadsheetPreviewError.archiveExpansionLimit
                }
                bytes = nextBytes
            }
        }
    }

    private func parseWorkbook(root: URL) throws -> SpreadsheetPreview {
        let sharedURL = root.appending(path: "xl/sharedStrings.xml")
        let sharedStrings = fileManager.fileExists(atPath: sharedURL.path)
            ? try SharedStringsXMLParser.parse(url: sharedURL) : []
        let workbookURL = root.appending(path: "xl/workbook.xml")
        let references = fileManager.fileExists(atPath: workbookURL.path)
            ? try WorkbookNamesXMLParser.parse(url: workbookURL) : []
        let worksheets = root.appending(path: "xl/worksheets", directoryHint: .isDirectory)
        let discoveredURLs = try fileManager.contentsOfDirectory(
            at: worksheets,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "xml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let relationshipsURL = root.appending(path: "xl/_rels/workbook.xml.rels")
        let relationships = fileManager.fileExists(atPath: relationshipsURL.path)
            ? try WorkbookRelationshipsXMLParser.parse(url: relationshipsURL) : [:]
        var ordered: [(URL, String)] = []
        for reference in references {
            guard let relationshipID = reference.relationshipID,
                  let target = relationships[relationshipID] else {
                throw SpreadsheetPreviewError.malformedWorkbook
            }
            guard target.hasPrefix("worksheets/"), target.hasSuffix(".xml"),
                  XLSXArchivePolicy().isSafeRelativePath(target) else {
                throw SpreadsheetPreviewError.unsafeArchiveEntry(target)
            }
            let url = root.appending(path: "xl", directoryHint: .isDirectory).appending(path: target)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SpreadsheetPreviewError.malformedWorkbook
            }
            ordered.append((url, reference.name))
        }
        let sheetEntries: [(URL, String)] = !references.isEmpty
            ? ordered
            : discoveredURLs.enumerated().map { index, url in
                (url, index < references.count ? references[index].name : "Sheet \(index + 1)")
            }
        guard !sheetEntries.isEmpty else { throw SpreadsheetPreviewError.malformedWorkbook }

        var sheets: [SpreadsheetPreview.Sheet] = []
        for (url, name) in sheetEntries.prefix(SpreadsheetPreviewLimits.sheets) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SpreadsheetPreviewError.unsafeArchiveEntry(url.lastPathComponent)
            }
            let rows = try WorksheetXMLParser.parse(url: url, sharedStrings: sharedStrings)
            sheets.append(.init(id: url.lastPathComponent, name: name, rows: rows))
        }
        return SpreadsheetPreview(sheets: sheets, isTruncated: sheetEntries.count > SpreadsheetPreviewLimits.sheets)
    }
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int64 = 10 * 1_024 * 1_024,
        temporaryRoot: URL? = nil,
        monitoredDirectory: URL? = nil,
        maxMonitoredBytes: Int64? = nil,
        maxMonitoredEntries: Int? = nil
    ) throws -> Data {
        let fileManager = FileManager.default
        let directory = (temporaryRoot ?? fileManager.temporaryDirectory)
            .appending(path: "FiliconProcess-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stdoutURL = directory.appending(path: "stdout")
        let stderrURL = directory.appending(path: "stderr")
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw SpreadsheetPreviewError.processFailed
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            if semaphore.wait(timeout: .now() + 0.05) == .success {
                finished = true
                break
            }
            let stdoutSize = (try? fileManager.attributesOfItem(atPath: stdoutURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let stderrSize = (try? fileManager.attributesOfItem(atPath: stderrURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if stdoutSize > maxOutputBytes || stderrSize > maxOutputBytes {
                stop(process, semaphore: semaphore)
                throw SpreadsheetPreviewError.archiveEntryLimit
            }
            if let monitoredDirectory {
                do {
                    if let violation = try monitorViolation(
                        at: monitoredDirectory,
                        fileManager: fileManager,
                        maxBytes: maxMonitoredBytes,
                        maxEntries: maxMonitoredEntries
                    ) {
                        stop(process, semaphore: semaphore)
                        throw violation
                    }
                } catch let error as SpreadsheetPreviewError {
                    stop(process, semaphore: semaphore)
                    throw error
                } catch {
                    stop(process, semaphore: semaphore)
                    throw SpreadsheetPreviewError.processFailed
                }
            }
        }
        if !finished {
            stop(process, semaphore: semaphore)
            throw SpreadsheetPreviewError.processFailed
        }
        guard process.terminationStatus == 0 else { throw SpreadsheetPreviewError.processFailed }
        try stdout.synchronize()
        return try Data(contentsOf: stdoutURL)
    }

    private static func stop(_ process: Process, semaphore: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            // Some archive helpers can be stuck in uninterruptible or hostile
            // input paths. Never return while a timed-out child is still alive.
            kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + 2)
        }
    }

    private static func monitorViolation(
        at root: URL,
        fileManager: FileManager,
        maxBytes: Int64?,
        maxEntries: Int?
    ) throws -> SpreadsheetPreviewError? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return .processFailed }
        var entries = 0
        var bytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            entries += 1
            if let maxEntries, entries > maxEntries { return .archiveEntryLimit }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { return .unsafeArchiveEntry(url.lastPathComponent) }
            if values.isRegularFile == true {
                let (sum, overflow) = bytes.addingReportingOverflow(Int64(values.fileSize ?? 0))
                if overflow { return .archiveExpansionLimit }
                bytes = sum
                if let maxBytes, bytes > maxBytes { return .archiveExpansionLimit }
            }
        }
        return nil
    }
}

private struct WorkbookSheetReference {
    let name: String
    let relationshipID: String?
}

private final class WorkbookNamesXMLParser: NSObject, XMLParserDelegate {
    private(set) var references: [WorkbookSheetReference] = []
    private var exceededLimit = false

    static func parse(url: URL) throws -> [WorkbookSheetReference] {
        let delegate = WorkbookNamesXMLParser()
        let parser = try SafeOfficeXMLParser.make(url: url)
        parser.delegate = delegate
        guard parser.parse() || delegate.exceededLimit else { throw SpreadsheetPreviewError.malformedWorkbook }
        return delegate.references
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "sheet", let name = attributeDict["name"] {
            if references.count >= SpreadsheetPreviewLimits.sheets + 1 {
                exceededLimit = true
                parser.abortParsing()
                return
            }
            references.append(.init(
                name: String(name.prefix(256)),
                relationshipID: attributeDict["r:id"]
            ))
        }
    }
}

private final class WorkbookRelationshipsXMLParser: NSObject, XMLParserDelegate {
    private(set) var relationships: [String: String] = [:]
    private var exceededLimit = false

    static func parse(url: URL) throws -> [String: String] {
        let delegate = WorkbookRelationshipsXMLParser()
        let parser = try SafeOfficeXMLParser.make(url: url)
        parser.delegate = delegate
        guard parser.parse() || delegate.exceededLimit else { throw SpreadsheetPreviewError.malformedWorkbook }
        return delegate.relationships
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship",
              attributeDict["TargetMode"]?.lowercased() != "external",
              let identifier = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        if relationships.count >= SpreadsheetPreviewLimits.relationships {
            exceededLimit = true
            parser.abortParsing()
            return
        }
        relationships[identifier] = target
    }
}

private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var insideItem = false
    private var insideText = false
    private var value = ""
    private var totalCharacters = 0
    private var limitError: SpreadsheetPreviewError?

    static func parse(url: URL) throws -> [String] {
        let delegate = SharedStringsXMLParser()
        let parser = try SafeOfficeXMLParser.make(url: url)
        parser.delegate = delegate
        guard parser.parse() else {
            if let error = delegate.limitError { throw error }
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" { insideItem = true; value = "" }
        if elementName == "t", insideItem { insideText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideText { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { insideText = false }
        if elementName == "si" {
            guard value.count <= SpreadsheetPreviewLimits.cellCharacters else {
                limitError = .textLimit; parser.abortParsing(); return
            }
            totalCharacters += value.count
            guard totalCharacters <= SpreadsheetPreviewLimits.totalCharacters,
                  strings.count < SpreadsheetPreviewLimits.sharedStrings else {
                limitError = .textLimit; parser.abortParsing(); return
            }
            strings.append(value)
            insideItem = false
        }
    }
}

private final class WorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var rows: [[String]] = []
    private var currentRow: [String] = []
    private var currentColumn = 0
    private var cellType: String?
    private var cellValue = ""
    private var readingValue = false
    private var readingInlineText = false
    private var totalCharacters = 0
    private var limitError: SpreadsheetPreviewError?

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    static func parse(url: URL, sharedStrings: [String]) throws -> [[String]] {
        let delegate = WorksheetXMLParser(sharedStrings: sharedStrings)
        let parser = try SafeOfficeXMLParser.make(url: url)
        parser.delegate = delegate
        guard parser.parse(), delegate.limitError == nil else {
            if let error = delegate.limitError { throw error }
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            guard rows.count < SpreadsheetPreviewLimits.rows else {
                limitError = .rowLimit; parser.abortParsing(); return
            }
            currentRow = []
        case "c":
            cellType = attributeDict["t"]
            currentColumn = attributeDict["r"].map(Self.columnIndex(from:)) ?? currentRow.count
            guard currentColumn < SpreadsheetPreviewLimits.columns else {
                limitError = .columnLimit; parser.abortParsing(); return
            }
            cellValue = ""
        case "v": readingValue = true
        case "t" where cellType == "inlineStr": readingInlineText = true
        default: break // Formula (`f`) and all active/linked content are ignored.
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingValue || readingInlineText { cellValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v": readingValue = false
        case "t": readingInlineText = false
        case "c":
            let resolved: String
            if cellType == "s", let index = Int(cellValue), sharedStrings.indices.contains(index) {
                resolved = sharedStrings[index]
            } else if cellType == "b" {
                resolved = cellValue == "1" ? "TRUE" : "FALSE"
            } else {
                resolved = cellValue
            }
            guard resolved.count <= SpreadsheetPreviewLimits.cellCharacters else {
                limitError = .textLimit; parser.abortParsing(); return
            }
            while currentRow.count < currentColumn { currentRow.append("") }
            currentRow.append(resolved)
            totalCharacters += resolved.count
            guard totalCharacters <= SpreadsheetPreviewLimits.totalCharacters else {
                limitError = .textLimit; parser.abortParsing(); return
            }
        case "row": rows.append(currentRow)
        default: break
        }
    }

    private static func columnIndex(from reference: String) -> Int {
        var value = 0
        for scalar in reference.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            if value >= SpreadsheetPreviewLimits.columns { return SpreadsheetPreviewLimits.columns }
            value = value * 26 + Int(scalar.value - 64)
            if value > SpreadsheetPreviewLimits.columns { return SpreadsheetPreviewLimits.columns }
        }
        return max(0, value - 1)
    }
}

private enum SafeOfficeXMLParser {
    static func make(url: URL) throws -> XMLParser {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= SpreadsheetPreviewLimits.xmlBytes else {
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // Office Open XML produced by mainstream spreadsheet apps is UTF-8.
        // Reject UTF-16 here so declaration filtering cannot be bypassed with
        // interleaved NUL bytes.
        guard !data.prefix(256).contains(0) else { throw SpreadsheetPreviewError.malformedWorkbook }
        guard !containsASCIIInsensitive(data, token: Array("<!doctype".utf8)),
              !containsASCIIInsensitive(data, token: Array("<!entity".utf8)) else {
            throw SpreadsheetPreviewError.malformedWorkbook
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        return parser
    }

    private static func containsASCIIInsensitive(_ data: Data, token: [UInt8]) -> Bool {
        guard data.count >= token.count else { return false }
        for start in 0...(data.count - token.count) {
            var matches = true
            for offset in token.indices {
                let byte = data[data.index(data.startIndex, offsetBy: start + offset)]
                let lowercased = (65...90).contains(byte) ? byte + 32 : byte
                if lowercased != token[offset] { matches = false; break }
            }
            if matches { return true }
        }
        return false
    }
}
