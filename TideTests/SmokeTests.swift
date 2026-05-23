import XCTest
@testable import Tide

final class SmokeTests: XCTestCase {
    func testISO8601RoundTrip() {
        let s = ISO8601.now()
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.contains("T"))
        XCTAssertTrue(s.hasSuffix("Z"))
    }

    func testHardcodedRulesNonEmpty() {
        XCTAssertTrue(HardcodedIgnoreRules.exactNames.contains(".DS_Store"))
    }
}
