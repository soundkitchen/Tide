import XCTest
import TideCore
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

    /// テスト環境で XCTest 検出が true を返すことを固定する。
    /// これが false だと AppEnvironment.bootstrap の eager bootstrap 抑止ガードが効かず、
    /// テスト実行中に本体アプリが実 S3 と同期してしまう。
    func testIsRunningXCTestsDetected() {
        XCTAssertTrue(ProcessInfo.processInfo.isRunningXCTests)
    }
}
