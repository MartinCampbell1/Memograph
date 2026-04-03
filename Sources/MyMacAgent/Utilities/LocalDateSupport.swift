import Foundation

struct LocalDateSupport {
    let timeZone: TimeZone

    init(timeZone: TimeZone = .autoupdatingCurrent) {
        self.timeZone = timeZone
    }

    func currentLocalDateString(now: Date = Date()) -> String {
        localDayFormatter.string(from: now)
    }

    func utcRange(forLocalDate dateString: String) -> (start: String, end: String)? {
        guard let startOfDay = localDayFormatter.date(from: dateString),
              let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return nil
        }
        return (utcFormatter.string(from: startOfDay), utcFormatter.string(from: endOfDay))
    }

    func startOfLocalDay(for dateString: String) -> Date? {
        localDayFormatter.date(from: dateString)
    }

    func endOfLocalDay(for dateString: String) -> Date? {
        guard let startOfDay = startOfLocalDay(for: dateString) else { return nil }
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
    }

    func localDateString(from date: Date) -> String {
        localDayFormatter.string(from: date)
    }

    func localTimeString(from date: Date) -> String {
        localTimeFormatter.string(from: date)
    }

    func localDateTimeString(from date: Date) -> String {
        localDateTimeFormatter.string(from: date)
    }

    func isoString(from date: Date) -> String {
        utcFormatter.string(from: date)
    }

    func localDateString(from isoString: String) -> String? {
        guard let date = parseDateTime(isoString) else { return nil }
        return localDayFormatter.string(from: date)
    }

    func localTimeString(from isoString: String) -> String {
        guard let date = parseDateTime(isoString) else { return isoString }
        return localTimeFormatter.string(from: date)
    }

    func localDateTimeString(from isoString: String) -> String {
        guard let date = parseDateTime(isoString) else { return isoString }
        return localDateTimeFormatter.string(from: date)
    }

    func offsetLocalDateString(_ dateString: String, by days: Int) -> String? {
        guard let date = localDayFormatter.date(from: dateString),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else {
            return nil
        }
        return localDayFormatter.string(from: shifted)
    }

    func parseDateTime(_ value: String) -> Date? {
        if let isoDate = parseISO8601(value) {
            return isoDate
        }

        for formatter in sqliteFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    func effectiveDurationMs(
        startedAt: String,
        endedAt: String?,
        storedActiveDurationMs: Int64,
        now: Date = Date()
    ) -> Int64 {
        guard let startDate = parseDateTime(startedAt) else {
            return storedActiveDurationMs
        }

        let endDate = endedAt.flatMap(parseDateTime) ?? now
        let computedDurationMs = max(0, Int64(endDate.timeIntervalSince(startDate) * 1000))
        return max(storedActiveDurationMs, computedDurationMs)
    }

    func overlapDurationMs(
        startedAt: String,
        endedAt: String?,
        rangeStart: Date,
        rangeEnd: Date,
        now: Date = Date()
    ) -> Int64 {
        guard let sessionStart = parseDateTime(startedAt) else {
            return 0
        }

        let sessionEnd = endedAt.flatMap(parseDateTime) ?? now
        let overlapStart = max(sessionStart, rangeStart)
        let overlapEnd = min(sessionEnd, rangeEnd)
        guard overlapEnd > overlapStart else {
            return 0
        }

        return Int64(overlapEnd.timeIntervalSince(overlapStart) * 1000)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var localDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private var localTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private var localDateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private var utcFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private var sqliteFormatters: [DateFormatter] {
        let patterns = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS"
        ]

        return patterns.flatMap { pattern in
            [timeZone, TimeZone(secondsFromGMT: 0) ?? timeZone].map { zone in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = zone
                formatter.dateFormat = pattern
                return formatter
            }
        }
    }

    private func parseISO8601(_ value: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options.withInternetDateTime,
            [.withInternetDateTime, .withFractionalSeconds]
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = options
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
