import XCTest
@testable import Tide

final class ManifestShardingTests: XCTestCase {
    func testStableForSamePath() {
        let p = "Documents/2026/report.pdf"
        XCTAssertEqual(ManifestSharding.shardId(for: p), ManifestSharding.shardId(for: p))
    }

    func testTwoHexDigits() {
        for p in ["a", "a/b", "Photos/IMG_0001.jpg", "🐦/tweet.txt", ".git/HEAD"] {
            let s = ManifestSharding.shardId(for: p)
            XCTAssertEqual(s.count, 2, "shard id should be 2 hex digits: \(s)")
            XCTAssertTrue(s.allSatisfy { $0.isHexDigit }, "must be hex: \(s)")
        }
    }

    func testDistributionIsRoughlyEven() {
        // 大量パスでビン偏りがそこそこ抑えられていることを確認
        var bins: [String: Int] = [:]
        for i in 0..<10_000 {
            let p = "dir\(i % 17)/sub\(i % 53)/file_\(i).txt"
            let s = ManifestSharding.shardId(for: p)
            bins[s, default: 0] += 1
        }
        XCTAssertGreaterThan(bins.count, 200, "should hit most of 256 buckets")
        let counts = bins.values.sorted()
        let median = counts[counts.count / 2]
        let max = counts.last ?? 0
        // 中央値の 5 倍を超える bin がないこと（緩いチェック）
        XCTAssertLessThan(max, median * 5, "max bin too skewed: max=\(max) median=\(median)")
    }
}
