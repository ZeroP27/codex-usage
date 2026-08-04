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

    static let compactDeadlineDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static let compactDeadlineDateTimeWithYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
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
        return compactDeadlineTime(date)
    }

    static func weeklyResetTime(_ date: Date?) -> String {
        guard let date else { return "unavailable" }
        return compactDeadlineTime(date)
    }

    static func resetCreditCount(_ count: Int) -> String {
        count == 1 ? "1 reset" : "\(count) resets"
    }

    static func compactDeadlineTime(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> String {
        let calendar = Calendar.current
        if calendar.component(.year, from: date)
            != calendar.component(.year, from: now)
        {
            return compactDeadlineDateTimeWithYear.string(from: date)
        }
        return compactDeadlineDateTime.string(from: date)
    }

    static func isImminentExpiry(
        _ date: Date,
        relativeTo now: Date = Date()
    ) -> Bool {
        let interval = date.timeIntervalSince(now)
        return interval > 0 && interval <= 48 * 60 * 60
    }
}
