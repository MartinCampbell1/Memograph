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

    func localDateString(from isoString: String) -> String? {
        guard let date = parseISO8601(isoString) else { return nil }
        return localDayFormatter.string(from: date)
    }

    func localTimeString(from isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return isoString }
        return localTimeFormatter.string(from: date)
    }

    func localDateTimeString(from isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return isoString }
        return localDateTimeFormatter.string(from: date)
    }

    func effectiveDurationMs(
        startedAt: String,
        endedAt: String?,
        storedActiveDurationMs: Int64,
        now: Date = Date()
    ) -> Int64 {
        guard let startDate = parseISO8601(startedAt) else {
            return storedActiveDurationMs
        }

        let endDate = endedAt.flatMap(parseISO8601) ?? now
        let computedDurationMs = max(0, Int64(endDate.timeIntervalSince(startDate) * 1000))
        return max(storedActiveDurationMs, computedDurationMs)
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
