import XCTest
import TideCore

/// FP 書込経路の純粋判定（M5 Phase 5-2）。itemVersion → 3-way ベース sha の逆写像を固定する。
final class FileProviderWritePolicyTests: XCTestCase {
    func testBaseShaAcceptsLowercaseSha256Hex() {
        let sha = String(repeating: "0123456789abcdef", count: 4)  // 64 桁 hex 小文字
        XCTAssertEqual(
            FileProviderWritePolicy.baseSha(fromContentVersion: Data(sha.utf8)), sha
        )
    }

    func testBaseShaRejectsDirectorySentinel() {
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data("dir".utf8)))
    }

    // MARK: - contentVersion 往復（PR #58 レビュー #8）

    /// file ノードは contentVersion(for:) → baseSha で往復する（符号化と復号の整合）。
    func testContentVersionRoundtripsForFile() {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        let entry = ManifestFileEntry(
            size: 1, mtime: "2026-07-06T00:00:00Z", sha256: sha,
            s3VersionId: nil, etag: "e", deviceId: "d", uploadedAt: "2026-07-06T00:00:00Z"
        )
        let cv = FileProviderWritePolicy.contentVersion(for: .file(path: "a.txt", entry: entry))
        XCTAssertEqual(FileProviderWritePolicy.baseSha(fromContentVersion: cv), sha)
    }

    /// directory ノードの contentVersion は base sha を持たない（"dir" → nil）。
    func testContentVersionForDirectoryHasNoBaseSha() {
        let cv = FileProviderWritePolicy.contentVersion(for: .directory(path: "d", mtime: nil))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: cv))
    }

    func testBaseShaRejectsNonShaShapes() {
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: nil))
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data()))
        // 大文字 hex（発行元は小文字固定 = 規約外）
        let upper = String(repeating: "0123456789ABCDEF", count: 4)
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data(upper.utf8)))
        // 長さ違い
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data("abc123".utf8)))
        // 非 hex 文字
        let bad = String(repeating: "0123456789abcdeg", count: 4)
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data(bad.utf8)))
        // 非 UTF-8
        XCTAssertNil(FileProviderWritePolicy.baseSha(fromContentVersion: Data([0xFF, 0xFE, 0x00])))
    }
}
