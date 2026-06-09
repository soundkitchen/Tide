import XCTest
@testable import Tide

/// `StabilityCheck.isStable`（torn read 防止の安定化判定）の純粋ロジック網羅。
final class StabilityCheckTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    func testStableWhenSizeAndMtimeUnchanged() {
        XCTAssertTrue(StabilityCheck.isStable(
            expectedSize: 1000, expectedMtime: base,
            finalSize: 1000, finalMtime: base
        ))
    }

    func testUnstableWhenSizeGrew() {
        XCTAssertFalse(StabilityCheck.isStable(
            expectedSize: 1000, expectedMtime: base,
            finalSize: 1200, finalMtime: base
        ), "読込中にサイズが増えた（成長中ファイル）→ 不安定")
    }

    func testUnstableWhenSizeShrank() {
        XCTAssertFalse(StabilityCheck.isStable(
            expectedSize: 1000, expectedMtime: base,
            finalSize: 800, finalMtime: base
        ))
    }

    func testUnstableWhenMtimeAdvanced() {
        XCTAssertFalse(StabilityCheck.isStable(
            expectedSize: 1000, expectedMtime: base,
            finalSize: 1000, finalMtime: base.addingTimeInterval(0.5)
        ), "サイズ据え置きでも in-place 書換で mtime が前進 → 不安定")
    }

    func testUnstableWhenBothChanged() {
        XCTAssertFalse(StabilityCheck.isStable(
            expectedSize: 1000, expectedMtime: base,
            finalSize: 2000, finalMtime: base.addingTimeInterval(3)
        ))
    }

    func testFileInfoSugarMatchesRawValues() {
        let a = NoFollowFileReader.FileInfo(size: 42, mtime: base)
        let b = NoFollowFileReader.FileInfo(size: 42, mtime: base)
        XCTAssertTrue(StabilityCheck.isStable(expected: a, final: b))
        let c = NoFollowFileReader.FileInfo(size: 43, mtime: base)
        XCTAssertFalse(StabilityCheck.isStable(expected: a, final: c))
    }
}
