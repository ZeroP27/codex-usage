import Foundation

@MainActor
enum UsageFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()

    static let compactDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d h:mm a"
        return formatter
    }()

    static let compactDateTimeWithYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy h:mm a"
        return formatter
    }()

    static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        let text = percentFormatter.string(from: NSNumber(value: clamped)) ?? String(format: "%.0f", clamped)
        return text + "%"
    }

    static func updatedAt(_ date: Date?) -> String {
        guard let date else { return "No updates yet" }
        if Calendar.current.isDateInToday(date) {
            return time.string(from: date)
        }
        return dateTime.string(from: date)
    }

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today \(time.string(from: date))"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow \(time.string(from: date))"
        }
        return dateTime.string(from: date)
    }

    static func weeklyResetTime(_ date: Date?) -> String {
        guard let date else { return "unavailable" }
        return weekdayTime.string(from: date)
    }

    static func resetCreditCount(_ count: Int) -> String {
        count == 1 ? "1 reset" : "\(count) resets"
    }

    static func compactExpiryTime(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "today \(time.string(from: date))"
        }
        if calendar.isDateInTomorrow(date) {
            return "tomorrow \(time.string(from: date))"
        }
        if calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        {
            return compactDateTime.string(from: date)
        }
        return compactDateTimeWithYear.string(from: date)
    }

    static func isImminentExpiry(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval <= 48 * 60 * 60
    }
}
