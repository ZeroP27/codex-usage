import Foundation

enum SafeNumericConversions {
    static func finiteDouble(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    static func exactInt(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
        return Int(exactly: value)
    }

    static func truncatingInt64(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        return Int64(exactly: value.rounded(.towardZero))
    }
}
