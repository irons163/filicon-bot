import Foundation

/// Protect TeX from Markdown's escape/emphasis parser without splitting its paragraph.
/// Tokens are deterministic and absent from the original source, including its TeX.
public struct MarkdownInlineMath: Sendable, Equatable {
    public struct Formula: Sendable, Equatable {
        public let token: String
        public let source: String
    }

    public let markdown: String
    public let formulas: [Formula]

    public enum Preparation: Sendable, Equatable {
        case plain
        case protected(MarkdownInlineMath)
        case rejected
    }

    /// Metadata sees ordinary prose/code, never addresses written inside TeX.
    /// A rejected oversized input does not gain automatic resource requests.
    public static func metadataSource(_ source: String) -> String? {
        guard source.utf8.count <= 262_144 else { return nil }
        let spans = MarkdownMathScanner.spans(in: source, mode: .inline, maximum: 129)
        guard spans.count <= 128 else { return nil }
        var result = "", cursor = source.startIndex
        for span in spans {
            result += source[cursor..<span.range.lowerBound] + " "
            cursor = span.range.upperBound
        }
        return result + source[cursor...]
    }

    public static func protect(_ source: String) -> Self? {
        guard case .protected(let value) = prepare(source) else { return nil }
        return value
    }

    /// A rejected preparation must not send TeX through Markdown's ordinary
    /// escape/link parser. The host can retain the entire original as literal text.
    public static func prepare(_ source: String) -> Preparation {
        guard source.utf8.count <= 262_144 else { return .rejected }
        let spans = MarkdownMathScanner.spans(in: source, mode: .inline, maximum: 129)
        guard spans.count <= 128 else { return .rejected }
        guard !spans.isEmpty else { return .plain }
        let salt = markerSalt(in: source)
        let prefix = "FILICONINLINEFORMULA\(salt)N"
        var markdown = "", cursor = source.startIndex
        var formulas: [Formula] = []
        for (index, span) in spans.enumerated() {
            let token = "\(prefix)\(index)END"
            markdown += source[cursor..<span.range.lowerBound] + token
            formulas.append(.init(token: token, source: span.source))
            cursor = span.range.upperBound
        }
        markdown += source[cursor...]
        return .protected(.init(markdown: markdown, formulas: formulas))
    }

    /// Inventory canonical marker prefixes once instead of rescanning the whole
    /// message for every occupied salt. Leading zeros cannot match our tokens.
    private static func markerSalt(in source: String) -> Int {
        var cursor = source.startIndex, occupied: Set<Int> = []
        while let prefix = source.range(of: "FILICONINLINEFORMULA", range: cursor..<source.endIndex) {
            cursor = prefix.upperBound
            let end = source[cursor...].firstIndex(where: { !"0123456789".contains($0) }) ?? source.endIndex
            if cursor < end, end < source.endIndex, source[end] == "N",
               let salt = Int(source[cursor..<end]), String(salt) == String(source[cursor..<end]) {
                occupied.insert(salt)
            }
            cursor = end
        }
        var salt = 0
        while occupied.contains(salt) { salt += 1 }
        return salt
    }
}

enum MarkdownMathScanner {
    struct Span {
        let range: Range<String.Index>
        let source: String
    }

    static func spans(in source: String, mode: MathMode, maximum: Int = .max) -> [Span] {
        let codeEnds = indexedCodeEnds(in: source)
        var cursor = source.startIndex, result: [Span] = [], destinationScanFailed = false, tagScanFailed = false
        while cursor < source.endIndex {
            if source[cursor] == "`", !isEscaped(cursor, in: source) {
                let markerEnd = source[cursor...].firstIndex(where: { $0 != "`" }) ?? source.endIndex
                let marker = String(source[cursor..<markerEnd])
                if let close = codeEnd(marker.count, after: markerEnd, in: codeEnds) { cursor = close; continue }
                cursor = markerEnd; continue
            }
            // Markdown destinations and reference definitions are addresses, not prose.
            if !destinationScanFailed, source[cursor...].hasPrefix("]("), !isEscaped(cursor, in: source) {
                if let end = destinationEnd(after: source.index(cursor, offsetBy: 2), in: source) {
                    cursor = end; continue
                }
                destinationScanFailed = true
            }
            if source[cursor] == "[", isReferenceDefinition(at: cursor, in: source) {
                cursor = source[cursor...].firstIndex(where: \.isNewline) ?? source.endIndex; continue
            }
            // Autolink addresses and HTML tag attributes are not formula text.
            if !tagScanFailed, source[cursor] == "<", !isEscaped(cursor, in: source) {
                if let end = source[cursor...].firstIndex(of: ">") {
                    cursor = source.index(after: end); continue
                }
                // No closer exists in this suffix. Repeating this search for
                // every later '<' would make a bounded message quadratic.
                tagScanFailed = true
            }
            let detected: MathMode
            if source[cursor...].hasPrefix("\\(") { detected = .inline }
            else if source[cursor...].hasPrefix("\\[") { detected = .display }
            else { cursor = source.index(after: cursor); continue }
            guard !isEscaped(cursor, in: source) else {
                cursor = source.index(after: cursor); continue
            }
            let closer = detected == .inline ? "\\)" : "\\]"
            let start = source.index(cursor, offsetBy: 2)
            let limit = detected == .inline ? source[start...].firstIndex(where: \.isNewline) ?? source.endIndex : source.endIndex
            var search = start, closing: Range<String.Index>?
            while search < limit, let candidate = source.range(of: closer, range: search..<limit) {
                if !isEscaped(candidate.lowerBound, in: source) { closing = candidate; break }
                search = candidate.upperBound
            }
            guard let closing else { cursor = limit; continue }
            if detected == mode {
                result.append(.init(range: cursor..<closing.upperBound, source: String(source[start..<closing.lowerBound])))
                if result.count >= maximum { return result }
            }
            cursor = closing.upperBound
        }
        return result
    }

    /// A code closer must be an entire run of the same length. Index each run
    /// once, including escaped ticks that are literal closers inside code spans.
    private static func indexedCodeEnds(in source: String) -> [Int: [String.Index]] {
        var cursor = source.startIndex, result: [Int: [String.Index]] = [:]
        while let start = source[cursor...].firstIndex(of: "`") {
            cursor = source.index(after: start)
            var count = 1
            while cursor < source.endIndex, source[cursor] == "`" {
                count += 1; cursor = source.index(after: cursor)
            }
            result[count, default: []].append(cursor)
        }
        return result
    }

    private static func codeEnd(_ count: Int, after start: String.Index, in index: [Int: [String.Index]]) -> String.Index? {
        guard let ends = index[count] else { return nil }
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] <= start { low = middle + 1 } else { high = middle }
        }
        return low < ends.count ? ends[low] : nil
    }

    private static func destinationEnd(after start: String.Index, in source: String) -> String.Index? {
        var cursor = start, depth = 1
        while cursor < source.endIndex {
            if !isEscaped(cursor, in: source) {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" { depth -= 1; if depth == 0 { return source.index(after: cursor) } }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isReferenceDefinition(at start: String.Index, in source: String) -> Bool {
        var cursor = start, spaces = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            if source[previous].isNewline { break }
            guard source[previous] == " ", spaces < 3 else { return false }
            spaces += 1; cursor = previous
        }
        let line = source[start...].prefix(while: { !$0.isNewline })
        guard let close = line.firstIndex(of: "]") else { return false }
        let next = source.index(after: close)
        return next < source.endIndex && source[next] == ":"
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var cursor = index, count = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            count += 1; cursor = previous
        }
        return !count.isMultiple(of: 2)
    }
}
