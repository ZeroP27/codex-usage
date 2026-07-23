import Foundation
import Testing
@testable import CodexUsageMonitor

struct SafeNumericConversionsTests {
    @Test
    func testFiniteDoubleRejectsNonFiniteValues() {
        #expect(SafeNumericConversions.finiteDouble(.nan) == nil)
        #expect(SafeNumericConversions.finiteDouble(.infinity) == nil)
        #expect(SafeNumericConversions.finiteDouble(-.infinity) == nil)
        #expect(SafeNumericConversions.finiteDouble(42.5) == 42.5)
    }

    @Test
    func testExactIntRejectsOutOfRangeAndFractionalValues() {
        #expect(SafeNumericConversions.exactInt(.nan) == nil)
        #expect(SafeNumericConversions.exactInt(.infinity) == nil)
        #expect(SafeNumericConversions.exactInt(Double.greatestFiniteMagnitude) == nil)
        #expect(SafeNumericConversions.exactInt(1.5) == nil)
        #expect(SafeNumericConversions.exactInt(42) == 42)
    }

    @Test
    func testTruncatingInt64RejectsNonFiniteAndOutOfRangeValues() {
        #expect(SafeNumericConversions.truncatingInt64(.nan) == nil)
        #expect(SafeNumericConversions.truncatingInt64(.infinity) == nil)
        #expect(
            SafeNumericConversions.truncatingInt64(Double.greatestFiniteMagnitude) == nil
        )
        #expect(SafeNumericConversions.truncatingInt64(1.9) == 1)
        #expect(SafeNumericConversions.truncatingInt64(-1.9) == -1)
        #expect(SafeNumericConversions.truncatingInt64(42) == 42)
        #expect(
            SafeNumericConversions.truncatingInt64(Double(Int64.min)) == Int64.min
        )
        #expect(SafeNumericConversions.truncatingInt64(Double(Int64.max)) == nil)
    }
}
