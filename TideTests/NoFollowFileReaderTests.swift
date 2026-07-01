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

    func testEmptyFileReadsNil() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("empty.bin")
        try Data().write(to: url)
        let reader = try NoFollowFileReader(path: url.path)
        XCTAssertNil(try reader.readChunk(4096))
    }
}
