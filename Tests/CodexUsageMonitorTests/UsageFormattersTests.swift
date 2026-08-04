import Foundation
import Testing
@testable import CodexUsageMonitor

struct UsageFormattersTests {
    @MainActor
    @Test
    func testCompactDeadlineUsesNumericMonthDayAndTwentyFourHourClock() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 4,
            hour: 12
        )))
        let deadline = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 13,
            hour: 2,
            minute: 8
        )))

        #expect(
            UsageFormatters.compactDeadlineTime(
                deadline,
                relativeTo: now
            ) == "08-13 02:08"
        )
    }

    @MainActor
    @Test
    func testCompactDeadlineKeepsTheSameShapeForTodayAndTomorrow() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 4,
            hour: 12
        )))
        let today = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 4,
            hour: 18,
            minute: 6
        )))
        let tomorrow = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 5,
            hour: 9,
            minute: 7
        )))

        #expect(
            UsageFormatters.compactDeadlineTime(
                today,
                relativeTo: now
            ) == "08-04 18:06"
        )
        #expect(
            UsageFormatters.compactDeadlineTime(
                tomorrow,
                relativeTo: now
            ) == "08-05 09:07"
        )
    }

    @MainActor
    @Test
    func testCompactDeadlineIncludesYearWhenItDiffers() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 12,
            day: 31,
            hour: 12
        )))
        let deadline = try #require(calendar.date(from: DateComponents(
            year: 2027,
            month: 1,
            day: 2,
            hour: 9
        )))

        #expect(
            UsageFormatters.compactDeadlineTime(
                deadline,
                relativeTo: now
            ) == "2027-01-02 09:00"
        )
    }
}
