import XCTest
import TideCore
@testable import Tide

/// 有界並列ヘルパ（ManifestReader / ManifestSnapshotLoader の共通骨格・PR #50 レビュー #7）。
final class BoundedParallelTests: XCTestCase {
    func testCollectsAllResultsBeyondLimit() async throws {
        // 上限より多いアイテムでも完了分を取りこぼさない（`group.next()` 破棄バグの回帰）
        let ids = Array(0..<50)
        let results = try await BoundedParallel.compactMap(ids, limit: 4) { id -> Int? in
            try await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000))
            return id * 2
        }
        XCTAssertEqual(results.count, 50)
        XCTAssertEqual(Set(results), Set(ids.map { $0 * 2 }))
    }

    func testNilResultsAreDropped() async throws {
        let results = try await BoundedParallel.compactMap(Array(0..<20), limit: 3) { id -> Int? in
            id.isMultiple(of: 2) ? id : nil
        }
        XCTAssertEqual(Set(results), Set(stride(from: 0, to: 20, by: 2)))
    }

    func testThrowPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await BoundedParallel.compactMap(Array(0..<10), limit: 2) { id -> Int? in
                if id == 5 { throw Boom() }
                return id
            }
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
