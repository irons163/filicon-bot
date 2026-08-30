import Foundation

public struct CronMatcher: Hashable, Sendable {
    public let minute: Set<Int>
    public let hour: Set<Int>
    public let dayOfMonth: Set<Int>
    public let month: Set<Int>
    public let dayOfWeek: Set<Int>
    public let isDayOfMonthRestricted: Bool
    public let isDayOfWeekRestricted: Bool
    public let timeZone: TimeZone?
}

public enum ScheduleError: LocalizedError, Equatable, Sendable {
    case invalidExpression, invalidTimeZone(String), noRunWithinSearchBound
    public var errorDescription: String? {
        switch self {
        case .invalidExpression: "Invalid automation schedule."
        case .invalidTimeZone(let value): "Invalid IANA time zone \(value)."
        case .noRunWithinSearchBound: "No scheduled instant exists within 366 days."
        }
    }
}

public enum AutomationSchedule {
    public static let maximumSearchMinutes = 366 * 24 * 60
    private static let aliases = [
        "@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *"
    ]

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func parseEvery(_ schedule: String) -> TimeInterval? {
        let pattern = #"^@every\s+(\d+)\s*([smhd])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let value = normalize(schedule)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges == 3,
              let amountRange = Range(match.range(at: 1), in: value),
              let unitRange = Range(match.range(at: 2), in: value),
              let amount = Double(value[amountRange]), amount > 0 else { return nil }
        let multiplier: Double = switch value[unitRange].lowercased() {
        case "s": 1
        case "m": 60
        case "h": 3_600
        case "d": 86_400
        default: 0
        }
        return multiplier > 0 ? amount * multiplier : nil
    }

    public static func compile(_ raw: String, defaultTimeZone: TimeZone? = nil) throws -> CronMatcher {
        var schedule = normalize(raw)
        var zone = defaultTimeZone
        if let match = schedule.range(of: #"^(?:CRON_TZ|TZ)=([^\s]+)\s+"#, options: .regularExpression) {
            let prefix = String(schedule[match])
            let identifier = prefix.split(separator: "=", maxSplits: 1)[1].split(whereSeparator: \.isWhitespace)[0].description
            guard let parsed = TimeZone(identifier: identifier) else { throw ScheduleError.invalidTimeZone(identifier) }
            zone = parsed
            schedule.removeSubrange(match)
        }
        schedule = aliases[schedule.lowercased()] ?? schedule
        let fields = schedule.split(separator: " ").map(String.init)
        guard fields.count == 5,
              let minute = parseField(fields[0], minimum: 0, maximum: 59),
              let hour = parseField(fields[1], minimum: 0, maximum: 23),
              let dayOfMonth = parseField(fields[2], minimum: 1, maximum: 31),
              let month = parseField(fields[3], minimum: 1, maximum: 12),
              let rawDayOfWeek = parseField(fields[4], minimum: 0, maximum: 7) else {
            throw ScheduleError.invalidExpression
        }
        return .init(
            minute: minute, hour: hour, dayOfMonth: dayOfMonth, month: month,
            dayOfWeek: Set(rawDayOfWeek.map { $0 == 7 ? 0 : $0 }),
            isDayOfMonthRestricted: fields[2] != "*",
            isDayOfWeekRestricted: fields[4] != "*",
            timeZone: zone
        )
    }

    public static func nextRun(
        for raw: String,
        after: Date,
        defaultTimeZone: TimeZone? = nil
    ) throws -> Date {
        let normalized = normalize(raw)
        if let interval = parseEvery(normalized) { return after.addingTimeInterval(interval) }
        let matcher = try compile(normalized, defaultTimeZone: defaultTimeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = matcher.timeZone ?? defaultTimeZone ?? .current
        let afterWall = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        let baseSeconds = floor(after.timeIntervalSince1970 / 60) * 60
        for offset in 1...maximumSearchMinutes {
            let candidate = Date(timeIntervalSince1970: baseSeconds + Double(offset * 60))
            let wall = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            guard let minute = wall.minute, let hour = wall.hour, let day = wall.day,
                  let month = wall.month, let weekday = wall.weekday else { continue }
            if wall.year == afterWall.year, wall.month == afterWall.month, wall.day == afterWall.day,
               wall.hour == afterWall.hour, wall.minute == afterWall.minute { continue }
            let zeroBasedWeekday = weekday - 1
            let dom = matcher.dayOfMonth.contains(day)
            let dow = matcher.dayOfWeek.contains(zeroBasedWeekday)
            let dayMatches = matcher.isDayOfMonthRestricted && matcher.isDayOfWeekRestricted
                ? dom || dow
                : (matcher.isDayOfMonthRestricted ? dom : true) && (matcher.isDayOfWeekRestricted ? dow : true)
            if matcher.minute.contains(minute), matcher.hour.contains(hour), matcher.month.contains(month), dayMatches {
                return candidate
            }
        }
        throw ScheduleError.noRunWithinSearchBound
    }

    private static func parseField(_ field: String, minimum: Int, maximum: Int) -> Set<Int>? {
        var values: Set<Int> = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let stepParts = part.split(separator: "/", omittingEmptySubsequences: false)
            guard stepParts.count <= 2,
                  let step = stepParts.count == 2 ? Int(stepParts[1]) : 1,
                  step > 0 else { return nil }
            let rangePart = String(stepParts[0])
            let start: Int, end: Int
            if rangePart == "*" || rangePart.isEmpty {
                start = minimum; end = maximum
            } else if rangePart.contains("-") {
                let bounds = rangePart.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2, let lower = Int(bounds[0]), let upper = Int(bounds[1]) else { return nil }
                start = lower; end = upper
            } else {
                guard let single = Int(rangePart) else { return nil }
                start = single; end = stepParts.count == 2 ? maximum : single
            }
            guard start >= minimum, end <= maximum, start <= end else { return nil }
            for value in stride(from: start, through: end, by: step) { values.insert(value) }
        }
        return values.isEmpty ? nil : values
    }
}
