import XCTest
import CryptoKit
import TideCore
@testable import Tide

final class NoFollowFileReaderTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testReadsRegularFileAndHashMatches() throws {
        let dir = tempDir()
        var data = Data(count: 200_000)
        data.withUnsafeMutableBytes { p in
            for i in 0..<p.count { p[i] = UInt8(i % 251) }
        }
        let url = dir.appendingPathComponent("f.bin")
        try data.write(to: url)

        let reader = try NoFollowFileReader(path: url.path)
        // 小さいチャンクサイズで読んでも全体が再構築され、SHA が一致する（短い read の蓄積も検証）。
        let (read, sha) = try HashCalculator.readAllAndHash(reader, chunkSize: 4096)
        XCTAssertEqual(read, data)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, expected)
    }

    func testRejectsSymlink() throws {
        let dir = tempDir()
        let target = dir.appendingPathComponent("target.txt")
        try Data("secret".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try NoFollowFileReader(path: link.path)) { error in
            guard case FileOpenError.isSymbolicLink = error else {
                return XCTFail("expected isSymbolicLink, got \(error)")
            }
        }
    }

    func testNotFoundThrows() {
        let missing = "/\(UUID().uuidString)/\(UUID().uuidString)"
        XCTAssertThrowsError(try NoFollowFileReader(path: missing))
    }

    /// dir → file 置換の鏡像（PR #53 レビュー #5）: 祖先がファイルだと open は ENOTDIR(20) で失敗する。
    /// Uploader の delete 変換（`.io(errno: ENOTDIR)` catch）が依存する errno マッピングを固定する。
    func testAncestorFileThrowsENOTDIR() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: f)
        XCTAssertThrowsError(try NoFollowFileReader(path: f.appendingPathComponent("child").path)) { error in
            guard case FileOpenError.io(let errno) = error, errno == ENOTDIR else {
                return XCTFail("expected io(ENOTDIR), got \(error)")
            }
        }
    }

    /// Issue #52: ディレクトリは open(O_RDONLY) が成功してしまう（EISDIR は read 時）ので、
    /// init の fstat で `.isDirectory` として先に拒否する。ファイル → 同名ディレクトリ置換を
    /// Uploader が read 前に判別（delete へ変換）できるようにするための前提。
    func testRejectsDirectory() throws {
        let dir = tempDir()
        let sub = dir.appendingPathComponent("was-a-file.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        XCTAssertThrowsError(try NoFollowFileReader(path: sub.path)) { error in
            guard case FileOpenError.isDirectory = error else {
                return XCTFail("expected isDirectory, got \(error)")
            }
        }
    }

    /// Uploader の upload → delete 変換条件（`isPathNoLongerRegularFile`）の分類を固定する
    /// （PR #53 再レビュー nit で catch を where 句 + 本プロパティへ変更）。
    func testIsPathNoLongerRegularFileClassification() {
        XCTAssertTrue(FileOpenError.notFound.isPathNoLongerRegularFile)
        XCTAssertTrue(FileOpenError.isDirectory.isPathNoLongerRegularFile)
        XCTAssertTrue(FileOpenError.io(errno: ENOTDIR).isPathNoLongerRegularFile)
        XCTAssertFalse(FileOpenError.isSymbolicLink.isPathNoLongerRegularFile, "symlink 置換は delete にしない（文書化済みポリシー）")
        XCTAssertFalse(FileOpenError.io(errno: EACCES).isPathNoLongerRegularFile)
    }

    func testEmptyFileReadsNil() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("empty.bin")
        try Data().write(to: url)
        let reader = try NoFollowFileReader(path: url.path)
        XCTAssertNil(try reader.readChunk(4096))
    }
}
