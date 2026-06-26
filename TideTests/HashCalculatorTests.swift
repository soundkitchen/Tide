import XCTest
import CryptoKit
@testable import Tide

final class HashCalculatorTests: XCTestCase {
    func testEmptyFile() throws {
        let url = try makeTempFile(content: Data())
        let h = try HashCalculator.sha256(of: url)
        XCTAssertEqual(h, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testKnownString() throws {
        let url = try makeTempFile(content: Data("hello".utf8))
        let h = try HashCalculator.sha256(of: url)
        XCTAssertEqual(h, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testLargeFileMatchesCryptoKit() throws {
        var data = Data(count: 200_000)
        data.withUnsafeMutableBytes { ptr in
            for i in 0..<ptr.count {
                ptr[i] = UInt8(i % 251)
            }
        }
        let url = try makeTempFile(content: data)
        let h = try HashCalculator.sha256(of: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(h, expected)
    }

    // MARK: - sha256NoFollow（#31 / D2）

    func testNoFollowMatchesFollowForRegularFile() throws {
        var data = Data(count: 200_000)   // 複数チャンクをまたぐサイズで連結も検証
        data.withUnsafeMutableBytes { ptr in
            for i in 0..<ptr.count { ptr[i] = UInt8(i % 251) }
        }
        let url = try makeTempFile(content: data)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try HashCalculator.sha256NoFollow(of: url), expected)
        // FOLLOW 版（通常ファイルでは同値）とも一致。
        XCTAssertEqual(try HashCalculator.sha256NoFollow(of: url), try HashCalculator.sha256(of: url))
    }

    func testNoFollowEmptyFile() throws {
        let url = try makeTempFile(content: Data())
        XCTAssertEqual(try HashCalculator.sha256NoFollow(of: url),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testNoFollowRejectsSymbolicLink() throws {
        let target = try makeTempFile(content: Data("secret".utf8))
        let link = target.deletingLastPathComponent().appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // FOLLOW 版はリンク先を読んでしまう（旧挙動の確認）。
        XCTAssertEqual(try HashCalculator.sha256(of: link), try HashCalculator.sha256(of: target))
        // NoFollow 版はリンク先を読まず ELOOP で弾く。
        XCTAssertThrowsError(try HashCalculator.sha256NoFollow(of: link)) { error in
            guard case FileOpenError.isSymbolicLink = error else {
                return XCTFail("expected isSymbolicLink, got \(error)")
            }
        }
    }

    func testNoFollowMissingFileThrowsNotFound() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-missing-\(UUID().uuidString).bin")
        XCTAssertThrowsError(try HashCalculator.sha256NoFollow(of: url)) { error in
            guard case FileOpenError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    private func makeTempFile(content: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tide-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.bin")
        try content.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return url
    }
}
