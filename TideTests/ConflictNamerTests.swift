import XCTest
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
}
