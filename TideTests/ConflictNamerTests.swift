import XCTest
import TideCore
@testable import Tide

final class ConflictNamerTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_716_534_896)  // 2024-05-24 ~12:34:56 UTC

    func testInsertsSuffixBeforeExtension() {
        let s = ConflictNamer.localCopyRelativePath(for: "Documents/report.pdf", at: fixedDate)
        XCTAssertTrue(s.hasPrefix("Documents/report (local copy "), s)
        XCTAssertTrue(s.hasSuffix(").pdf"), s)
    }

    func testNoExtensionStillAppendsSuffix() {
        let s = ConflictNamer.localCopyRelativePath(for: "Makefile", at: fixedDate)
        XCTAssertTrue(s.hasPrefix("Makefile (local copy "), s)
        XCTAssertFalse(s.contains("."), s)
    }

    func testDotfilePreservedAsStem() {
        // ".gitignore" should be treated as a name with no extension.
        let s = ConflictNamer.localCopyRelativePath(for: ".gitignore", at: fixedDate)
        XCTAssertTrue(s.hasPrefix(".gitignore (local copy "), s)
    }

    func testMultiSegmentPath() {
        let s = ConflictNamer.localCopyRelativePath(for: "a/b/c/file.txt", at: fixedDate)
        XCTAssertTrue(s.hasPrefix("a/b/c/file (local copy "), s)
        XCTAssertTrue(s.hasSuffix(").txt"), s)
    }

    func testTimestampHasNoColons() {
        let s = ConflictNamer.localCopyRelativePath(for: "foo.txt", at: fixedDate)
        // colons would mess with some filesystems; verify they're stripped/replaced
        XCTAssertFalse(s.contains(":"), s)
    }

    /// タイムスタンプは `YYYY-MM-DD HH-MM-SS`（numeric・0 埋め・24 時間）で時系列ソート可能であること。
    /// ロケール表記（`Jun 16 2026 at 2-06-18 AM` 等）への退行を検出する。タイムゾーン依存を避けるため
    /// 実値ではなく書式（数字・桁・区切り）を pin する。`restoredCopyRelativePath` も同じ共通ロジック。
    func testTimestampIsNumericSortableFormat() {
        let local = ConflictNamer.localCopyRelativePath(for: "foo.txt", at: fixedDate)
        XCTAssertNotNil(
            local.range(of: #"^foo \(local copy \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\)\.txt$"#, options: .regularExpression),
            local
        )
        let restored = ConflictNamer.restoredCopyRelativePath(for: "foo.txt", at: fixedDate)
        XCTAssertNotNil(
            restored.range(of: #"^foo \(restored \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\)\.txt$"#, options: .regularExpression),
            restored
        )
    }
}
