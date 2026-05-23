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
