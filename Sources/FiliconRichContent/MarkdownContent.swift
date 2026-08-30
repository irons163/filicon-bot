import Foundation

public enum MathMode: Sendable, Equatable { case inline, display }

public struct MarkdownTable: Sendable, Equatable {
    public let headers: [String]
    public let rows: [[String]]
    public init(headers: [String], rows: [[String]]) { self.headers = headers; self.rows = rows }
}

public enum RichMarkdownBlock: Sendable, Equatable {
    case prose(String)
    case code(language: String?, source: String, isTerminated: Bool)
    case math(source: String, mode: MathMode)
    case table(MarkdownTable)
    case mermaid(source: String, presentation: MermaidPresentation)
}

public struct RichMarkdownParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> [RichMarkdownBlock] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [RichMarkdownBlock] = []
        var prose: [String] = []
        func flush() {
            guard !prose.isEmpty else { return }
            result.append(contentsOf: parseMath(in: prose.joined(separator: "\n")))
            prose.removeAll(keepingCapacity: true)
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = openingFence(line) {
                flush()
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count, !isClosingFence(lines[cursor], marker: fence.marker) {
                    body.append(lines[cursor]); cursor += 1
                }
                let terminated = cursor < lines.count
                let source = body.joined(separator: "\n")
                if terminated, fence.language?.lowercased() == "mermaid" {
                    result.append(.mermaid(source: source, presentation: MermaidParser().parse(source)))
                } else {
                    result.append(.code(language: fence.language, source: source, isTerminated: terminated))
                }
                index = terminated ? cursor + 1 : lines.count
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == "$$" {
                var cursor = index + 1
                var body: [String] = []
                while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces) != "$$" {
                    body.append(lines[cursor]); cursor += 1
                }
                if cursor < lines.count {
                    flush(); result.append(.math(source: body.joined(separator: "\n"), mode: .display))
                    index = cursor + 1; continue
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
                if start < end {
                    flush(); result.append(.math(source: String(trimmed[start..<end]), mode: .display))
                    index += 1; continue
                }
            }
            if index + 1 < lines.count, let table = parseTable(lines, at: index) {
                flush(); result.append(.table(table.value)); index = table.next; continue
            }
            prose.append(line); index += 1
        }
        flush()
        return result.filter { if case .prose(let value) = $0 { return !value.isEmpty }; return true }
    }

    private func openingFence(_ line: String) -> (marker: String, language: String?)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let char = trimmed.first!
        let marker = String(trimmed.prefix(while: { $0 == char }))
        guard marker.count >= 3 else { return nil }
        let tag = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return (marker, tag.isEmpty ? nil : String(tag.split(whereSeparator: \.isWhitespace).first!))
    }

    private func isClosingFence(_ line: String, marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.allSatisfy { $0 == marker.first } && trimmed.count >= marker.count
    }

    private func parseTable(_ lines: [String], at start: Int) -> (value: MarkdownTable, next: Int)? {
        guard start + 1 < lines.count else { return nil }
        // A delimiter row without a pipe is a setext heading, not a GFM table.
        guard containsUnescapedPipe(lines[start]) || containsUnescapedPipe(lines[start + 1]) else { return nil }
        let headers = cells(lines[start]), separator = cells(lines[start + 1])
        guard headers.count > 0, headers.count == separator.count,
              separator.allSatisfy({ cell in
                  let value = cell.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                  return value.count >= 3 && value.allSatisfy { $0 == "-" }
              }) else { return nil }
        var rows: [[String]] = [], cursor = start + 2
        while cursor < lines.count, lines[cursor].contains("|") {
            let row = cells(lines[cursor]); guard row.count == headers.count else { break }
            rows.append(row); cursor += 1
        }
        return (MarkdownTable(headers: headers, rows: rows), cursor)
    }

    private func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.first == "|" { value.removeFirst() }; if value.last == "|" { value.removeLast() }
        var cells: [String] = [], current = "", escaped = false
        for ch in value {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch); escaped = false
            }
            else if ch == "\\" { escaped = true }
            else if ch == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(ch) }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces)); return cells
    }

    private func containsUnescapedPipe(_ line: String) -> Bool {
        var escaped = false
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true }
            else if character == "|" { return true }
        }
        return false
    }

    private func parseMath(in prose: String) -> [RichMarkdownBlock] {
        // Deliberately only accepts explicit LaTeX delimiters. A single '$' is prose.
        var blocks: [RichMarkdownBlock] = [], cursor = prose.startIndex, proseStart = cursor
        func emitProse(_ end: String.Index) { if proseStart < end { blocks.append(.prose(String(prose[proseStart..<end]))) } }
        while cursor < prose.endIndex {
            let rest = prose[cursor...]
            let opener: String, closer: String, mode: MathMode
            if rest.hasPrefix("\\(") && !isEscaped(cursor, in: prose) { opener = "\\("; closer = "\\)"; mode = .inline }
            else if rest.hasPrefix("\\[") && !isEscaped(cursor, in: prose) { opener = "\\["; closer = "\\]"; mode = .display }
            else { cursor = prose.index(after: cursor); continue }
            let contentStart = prose.index(cursor, offsetBy: opener.count)
            guard let close = prose.range(of: closer, range: contentStart..<prose.endIndex) else { cursor = contentStart; continue }
            emitProse(cursor)
            blocks.append(.math(source: String(prose[contentStart..<close.lowerBound]), mode: mode))
            cursor = close.upperBound; proseStart = cursor
        }
        emitProse(prose.endIndex)
        return blocks
    }

    private func isEscaped(_ index: String.Index, in value: String) -> Bool {
        var cursor = index
        var count = 0
        while cursor > value.startIndex {
            let previous = value.index(before: cursor)
            guard value[previous] == "\\" else { break }
            count += 1; cursor = previous
        }
        return count.isMultiple(of: 2) == false
    }
}
